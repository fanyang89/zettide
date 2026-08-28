#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 7 ]] || {
    echo "usage: spdk-nvme-perf.sh TARGET READY_FILE LOG_DIR POOL_ID READ_POLICY DEVICE DEVICE" >&2
    exit 2
}

ready_file=$2
log_dir=$3
shift 5
devices=("$@")

perf_binary=${ZETTIDE_SPDK_NVME_PERF_BINARY:?ZETTIDE_SPDK_NVME_PERF_BINARY is required}
namespace_text=${ZETTIDE_POOL_DATA_PCIE_NAMESPACES:?ZETTIDE_POOL_DATA_PCIE_NAMESPACES is required}
io_depth=${ZETTIDE_SPDK_NVME_PERF_IO_DEPTH:-256}
core_mask=${ZETTIDE_SPDK_NVME_PERF_CORE_MASK:-0x3}
runtime=${ZETTIDE_SPDK_NVME_PERF_RUNTIME:-20}
warmup_time=${ZETTIDE_SPDK_NVME_PERF_WARMUP_TIME:-5}
namespaces=()
bdfs=()
association_lines=()
declare -A associated_names=()
perf_pid=""
monitor_pid=""
deferred_signal=0

[[ $EUID -eq 0 ]] || { echo "SPDK NVMe perf requires root" >&2; exit 2; }
[[ -x $perf_binary ]] || { echo "SPDK NVMe perf binary is unavailable: $perf_binary" >&2; exit 2; }
[[ ${#devices[@]} -eq 2 ]] || { echo "SPDK NVMe perf requires two devices" >&2; exit 2; }
[[ $io_depth =~ ^[1-9][0-9]*$ ]] || { echo "invalid SPDK NVMe perf I/O depth: $io_depth" >&2; exit 2; }
((io_depth <= 65535)) || { echo "SPDK NVMe perf I/O depth exceeds 65535: $io_depth" >&2; exit 2; }
[[ $core_mask =~ ^(0[xX][0-9a-fA-F]+|[1-9][0-9]*)$ ]] || { echo "invalid SPDK NVMe perf core mask: $core_mask" >&2; exit 2; }
[[ $runtime =~ ^[1-9][0-9]*$ ]] || { echo "invalid SPDK NVMe perf runtime: $runtime" >&2; exit 2; }
[[ $warmup_time =~ ^[0-9]+$ ]] || { echo "invalid SPDK NVMe perf warmup time: $warmup_time" >&2; exit 2; }
((runtime <= 86400)) || { echo "SPDK NVMe perf runtime exceeds 86400 seconds: $runtime" >&2; exit 2; }
((warmup_time <= 3600)) || { echo "SPDK NVMe perf warmup exceeds 3600 seconds: $warmup_time" >&2; exit 2; }
command -v prlimit >/dev/null || { echo "prlimit is required" >&2; exit 2; }
command -v stdbuf >/dev/null || { echo "stdbuf is required" >&2; exit 2; }

IFS=, read -r -a namespaces <<<"$namespace_text"
[[ ${#namespaces[@]} -eq 2 ]] || { echo "SPDK NVMe perf requires two PCIe namespaces" >&2; exit 2; }
for namespace in "${namespaces[@]}"; do
    [[ $namespace =~ ^([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])/1$ ]] || {
        echo "PCIe namespace must use canonical BDF/1 syntax: $namespace" >&2
        exit 2
    }
    bdfs+=("${BASH_REMATCH[1]}")
done
[[ ${bdfs[0]} != "${bdfs[1]}" ]] || { echo "PCIe controller BDFs must be distinct" >&2; exit 2; }

process_running() {
    local state=""
    kill -0 "$1" 2>/dev/null || return 1
    if [[ -r /proc/$1/stat ]]; then
        read -r _ _ state _ <"/proc/$1/stat" || true
        [[ $state != Z ]] || return 1
    fi
}

cleanup() {
    local result=$? deadline
    trap - EXIT HUP INT TERM
    set +e
    if [[ -n $perf_pid ]] && process_running "$perf_pid"; then
        kill -TERM "$perf_pid" 2>/dev/null || true
        deadline=$((SECONDS + 10))
        while process_running "$perf_pid" && ((SECONDS < deadline)); do
            sleep 0.1
        done
        if process_running "$perf_pid"; then
            echo "SPDK NVMe perf did not stop after TERM; sending KILL" >&2
            kill -KILL "$perf_pid" 2>/dev/null || true
            deadline=$((SECONDS + 3))
            while process_running "$perf_pid" && ((SECONDS < deadline)); do
                sleep 0.1
            done
        fi
        if process_running "$perf_pid"; then
            echo "SPDK NVMe perf remains running after KILL" >&2
            result=1
        fi
    fi
    [[ -z $perf_pid ]] || wait "$perf_pid" 2>/dev/null || true
    [[ -z $monitor_pid ]] || wait "$monitor_pid" 2>/dev/null || true
    exit "$result"
}

record_active_state() {
    local name=$1
    local interrupts_tmp=$log_dir/.host-interrupts-$name.$BASHPID
    local softirqs_tmp=$log_dir/.host-softirqs-$name.$BASHPID
    local pcie_tmp=$log_dir/.host-pcie-$name.$BASHPID
    local bdf pci_path irq_path irq affinity effective

    cp /proc/interrupts "$interrupts_tmp" || return 0
    cp /proc/softirqs "$softirqs_tmp" || {
        rm -f "$interrupts_tmp"
        return 0
    }
    {
        for bdf in "${bdfs[@]}"; do
            pci_path=/sys/bus/pci/devices/$bdf
            echo "== $bdf =="
            for irq_path in "$pci_path"/msi_irqs/*; do
                [[ -e $irq_path ]] || continue
                irq=${irq_path##*/}
                affinity=unavailable
                effective=unavailable
                [[ -r /proc/irq/$irq/smp_affinity_list ]] && affinity=$(<"/proc/irq/$irq/smp_affinity_list")
                [[ -r /proc/irq/$irq/effective_affinity_list ]] && effective=$(<"/proc/irq/$irq/effective_affinity_list")
                printf 'irq=%s affinity=%s effective=%s\n' "$irq" "$affinity" "$effective"
            done
        done
    } >"$pcie_tmp" || true
    if process_running "$perf_pid"; then
        mv "$interrupts_tmp" "$log_dir/host-interrupts-$name.txt"
        mv "$softirqs_tmp" "$log_dir/host-softirqs-$name.txt"
        mv "$pcie_tmp" "$log_dir/host-pcie-$name.txt"
    else
        rm -f "$interrupts_tmp" "$softirqs_tmp" "$pcie_tmp"
    fi
}

monitor_active_state() {
    local attempt start_epoch
    set +e
    while process_running "$perf_pid" &&
        ! grep -q '^Initialization complete\. Launching workers\.$' "$log_dir/perf.log"; do
        sleep 0.01
    done
    process_running "$perf_pid" || return 0
    for ((attempt = 0; attempt < 10; attempt++)); do
        process_running "$perf_pid" || return 0
        sleep 0.1
    done
    for ((attempt = 0; attempt < warmup_time * 10; attempt++)); do
        process_running "$perf_pid" || return 0
        sleep 0.1
    done
    process_running "$perf_pid" || return 0
    record_active_state measured-before
    start_epoch=$EPOCHREALTIME
    while process_running "$perf_pid"; do
        record_active_state measured-after-latest
        printf 'start_epoch=%s\nlatest_epoch=%s\n' "$start_epoch" "$EPOCHREALTIME" \
            >"$log_dir/host-measured-window.txt"
        sleep 1
    done
}

restore_signal_traps() {
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

begin_deferred_signals() {
    deferred_signal=0
    trap 'deferred_signal=129' HUP
    trap 'deferred_signal=130' INT
    trap 'deferred_signal=143' TERM
}

end_deferred_signals() {
    local signal=$deferred_signal
    restore_signal_traps
    deferred_signal=0
    ((signal == 0)) || exit "$signal"
}

trap cleanup EXIT
restore_signal_traps

mkdir -p "$log_dir"
: >"$ready_file"
command=(
    stdbuf --output=L --
    "$perf_binary"
    -q "$io_depth"
    -o 4096
    -w randread
    -t "$runtime"
    -a "$warmup_time"
    -c "$core_mask"
    -L
)
for bdf in "${bdfs[@]}"; do
    command+=(-b "$bdf")
done
for namespace in "${namespaces[@]}"; do
    bdf=${namespace%/1}
    command+=(-r "trtype:PCIe traddr:$bdf ns:1")
done

{
    echo "io_size=4096"
    echo "io_pattern=randread"
    echo "io_depth_per_worker=$io_depth"
    echo "core_mask=$core_mask"
    echo "runtime=$runtime"
    echo "warmup_time=$warmup_time"
    echo "namespaces=$namespace_text"
    printf 'command='
    printf '%q ' "${command[@]}"
    printf '\n'
} >"$log_dir/config.log"

begin_deferred_signals
prlimit --memlock=unlimited:unlimited -- "${command[@]}" >"$log_dir/perf.log" 2>&1 &
perf_pid=$!
monitor_active_state &
monitor_pid=$!
end_deferred_signals
perf_status=0
wait "$perf_pid" || perf_status=$?
perf_pid=""
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""
((perf_status == 0)) || exit "$perf_status"
[[ $(grep -c '^Attached to NVMe Controller at ' "$log_dir/perf.log") -eq 2 ]] || {
    echo "SPDK NVMe perf did not attach exactly two controllers" >&2
    exit 1
}
mapfile -t association_lines < <(grep -E '^Associating .* with lcore [0-9][0-9]*$' "$log_dir/perf.log")
for association in "${association_lines[@]}"; do
    name=${association#Associating }
    name=${name% with lcore *}
    associated_names["$name"]=1
done
[[ ${#associated_names[@]} -eq 2 ]] || {
    echo "SPDK NVMe perf did not schedule two distinct namespaces" >&2
    exit 1
}
if grep -q 'Removing this ns from test' "$log_dir/perf.log"; then
    echo "SPDK NVMe perf removed a namespace from the benchmark" >&2
    exit 1
fi
{
    echo "worker_contexts=${#association_lines[@]}"
    echo "namespace_count=${#associated_names[@]}"
    echo "aggregate_io_depth=$((io_depth * ${#association_lines[@]}))"
} >>"$log_dir/config.log"
grep -E '^Total[[:space:]]*:' "$log_dir/perf.log"
