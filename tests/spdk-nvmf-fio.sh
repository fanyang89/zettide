#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 3 ]] || {
    echo "usage: spdk-nvmf-fio.sh TARGET READY_FILE LOG_DIR [TARGET_ARG...]" >&2
    exit 2
}

target=$1
ready_file=$2
log_dir=$3
shift 3
runtime=${ZETTIDE_NVMF_FIO_RUNTIME:-20}
ramp_time=${ZETTIDE_NVMF_FIO_RAMP_TIME:-5}
fio_size=${ZETTIDE_NVMF_FIO_SIZE:-8G}
fio_case=${ZETTIDE_NVMF_FIO_CASE:-}
expected_size=${ZETTIDE_NVMF_EXPECTED_SIZE-68719476736}
nqn=nqn.2026-08.io.zettide:benchmark
serial=ZETTIDEBENCH000001
transport=${ZETTIDE_NVMF_TRANSPORT:-tcp}
target_addr=${ZETTIDE_NVMF_TARGET_ADDR:-127.0.0.1}
target_port=${ZETTIDE_NVMF_TARGET_PORT:-44220}
target_pid=""
device=""
rxe_target_if=ztnvmft0
rxe_target_device=ztnvmf_t
rxe_target_link_created=false
rxe_target_device_created=false
target_arguments=("$@")
case $fio_case in
    "" | seq-read-1m-qd32-j1 | seq-read-128k-qd1-j1 | randread-4k-qd1-j1 | randread-4k-qd32-j1 | randread-4k-qd32-j4 | randread-4k-qd32-j16) ;;
    *)
        echo "unknown NVMe-oF fio case: $fio_case" >&2
        exit 2
        ;;
esac
if [[ -n ${ZETTIDE_NVMF_TARGET_ARGUMENT:-} ]]; then
    target_arguments+=("$ZETTIDE_NVMF_TARGET_ARGUMENT")
fi
if [[ -n ${ZETTIDE_NVMF_TARGET_MODE:-} ]]; then
    target_arguments+=("$ZETTIDE_NVMF_TARGET_MODE")
fi
if [[ -n ${ZETTIDE_NVMF_TARGET_EXPECTED_POOL_ID:-} ]]; then
    target_arguments+=("$ZETTIDE_NVMF_TARGET_EXPECTED_POOL_ID")
fi

[[ $EUID -eq 0 ]] || {
    echo "NVMe-oF fio requires root" >&2
    exit 2
}
for command in blockdev fio jq lsblk modprobe nvme; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done
if [[ $transport == rdma ]]; then
    for command in ip prlimit rdma; do
        command -v "$command" >/dev/null || {
            echo "$command is required for RXE" >&2
            exit 2
        }
    done
elif [[ $transport != tcp ]]; then
    echo "unsupported NVMe-oF transport: $transport" >&2
    exit 2
fi

cleanup() {
    local result=$?
    local deadline state=""
    trap - EXIT INT TERM
    set +e
    nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
    if [[ -n $target_pid ]] && kill -0 "$target_pid" 2>/dev/null; then
        kill -TERM "$target_pid" 2>/dev/null || true
        deadline=$((SECONDS + 5))
        while kill -0 "$target_pid" 2>/dev/null && ((SECONDS < deadline)); do
            if [[ -r /proc/$target_pid/stat ]]; then
                read -r _ _ state _ <"/proc/$target_pid/stat" || true
                [[ $state != Z ]] || break
            fi
            sleep 0.1
        done
        if kill -0 "$target_pid" 2>/dev/null && [[ $state != Z ]]; then
            echo "NVMe-oF benchmark target did not stop after 5 seconds; sending KILL" >&2
            kill -KILL "$target_pid" 2>/dev/null || true
            result=1
            deadline=$((SECONDS + 2))
            while kill -0 "$target_pid" 2>/dev/null && ((SECONDS < deadline)); do
                if [[ -r /proc/$target_pid/stat ]]; then
                    read -r _ _ state _ <"/proc/$target_pid/stat" || true
                    [[ $state != Z ]] || break
                fi
                sleep 0.1
            done
        fi
        if ! kill -0 "$target_pid" 2>/dev/null || [[ $state == Z ]]; then
            wait "$target_pid" 2>/dev/null || true
        else
            echo "NVMe-oF benchmark target remains uninterruptible after KILL" >&2
            result=1
        fi
    fi
    if [[ $rxe_target_device_created == true ]]; then
        if ! rdma link delete "$rxe_target_device"; then
            echo "failed to delete RDMA device: $rxe_target_device" >&2
            result=1
        fi
    fi
    if [[ $rxe_target_link_created == true ]]; then
        if [[ -e /sys/class/net/$rxe_target_if ]] && ! ip link delete "$rxe_target_if"; then
            echo "failed to delete network interface: $rxe_target_if" >&2
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$log_dir"
rm -f "$ready_file"
nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
if [[ $transport == rdma ]]; then
    [[ ! -e /sys/class/net/$rxe_target_if ]] || {
        echo "network interface already exists: $rxe_target_if" >&2
        exit 1
    }
    [[ ! -e /sys/class/infiniband/$rxe_target_device ]] || {
        echo "RDMA device already exists: $rxe_target_device" >&2
        exit 1
    }

    modprobe rdma_rxe
    modprobe nvme-rdma
    ip link add "$rxe_target_if" type dummy
    rxe_target_link_created=true
    ip addr add "$target_addr"/32 dev "$rxe_target_if"
    ip link set "$rxe_target_if" up
    rdma link add "$rxe_target_device" type rxe netdev "$rxe_target_if"
    rxe_target_device_created=true

    rdma link show >"$log_dir/rdma-link-target.txt"
    ip addr show dev "$rxe_target_if" >"$log_dir/ip-link-target.txt"
    # shellcheck disable=SC2016 # Expand positional parameters in the child shell.
    prlimit --memlock=unlimited:unlimited -- \
        bash -c 'memlock_file=$1; shift; prlimit --pid $$ --memlock >"$memlock_file"; exec "$@"' \
        bash "$log_dir/memlock.txt" "$target" "$ready_file" "${target_arguments[@]}" \
        >"$log_dir/target.log" 2>&1 &
else
    modprobe nvme-tcp
    "$target" "$ready_file" "${target_arguments[@]}" >"$log_dir/target.log" 2>&1 &
fi
target_pid=$!
for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -f $ready_file ]] && break
    if ! kill -0 "$target_pid" 2>/dev/null; then
        wait "$target_pid" || true
        command cat "$log_dir/target.log" >&2
        exit 1
    fi
    sleep 0.01
done
[[ -f $ready_file ]] || {
    echo "NVMe-oF benchmark target did not become ready after 10 seconds" >&2
    command cat "$log_dir/target.log" >&2
    exit 1
}

nvme connect -t "$transport" -a "$target_addr" -s "$target_port" -n "$nqn"
for ((attempt = 0; attempt < 1000; attempt++)); do
    device=""
    while read -r name candidate; do
        if [[ $candidate == "$serial" ]]; then
            device=$name
            break
        fi
    done < <(lsblk --nodeps --noheadings --paths --output NAME,SERIAL)
    [[ -n $device ]] && break
    sleep 0.01
done
[[ -b $device ]] || {
    echo "NVMe-oF benchmark namespace did not appear" >&2
    exit 1
}

nvme list -o json >"$log_dir/nvme-list.json"
nvme list-subsys -o json >"$log_dir/nvme-list-subsys.json"
lsblk --bytes --output NAME,KNAME,TYPE,SIZE,MODEL,SERIAL "$device" >"$log_dir/lsblk.txt"
if [[ -n $expected_size ]]; then
    [[ $(blockdev --getsize64 "$device") -eq $expected_size ]]
fi

run_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local jobs=$5
    local size=$6
    fio --name="$name" --filename="$device" --rw="$rw" --bs="$block_size" \
        --size="$size" --offset_increment="$size" --ioengine=io_uring \
        --iodepth="$depth" --numjobs="$jobs" --direct=1 --readonly \
        --invalidate=1 --group_reporting=1 --time_based=1 --runtime="$runtime" \
        --ramp_time="$ramp_time" --randrepeat=0 --norandommap=1 \
        --percentile_list=50:95:99:99.9 --eta=never --output-format=json \
        --output="$log_dir/fio-$name.json"
    fio_results+=("$log_dir/fio-$name.json")
}

run_selected_case() {
    [[ -z $fio_case || $fio_case == "$1" ]] || return 0
    run_case "$@"
}

fio_results=()
run_selected_case seq-read-1m-qd32-j1 read 1m 32 1 "$fio_size"
run_selected_case seq-read-128k-qd1-j1 read 128k 1 1 "$fio_size"
run_selected_case randread-4k-qd1-j1 randread 4k 1 1 "$fio_size"
run_selected_case randread-4k-qd32-j1 randread 4k 32 1 "$fio_size"
run_selected_case randread-4k-qd32-j4 randread 4k 32 4 "$fio_size"
run_selected_case randread-4k-qd32-j16 randread 4k 32 16 "$fio_size"

for result in "${fio_results[@]}"; do
    jq -r '(.jobs[0].jobname) + " iops=" + (.jobs[0].read.iops|tostring) +
        " bw_bytes=" + (.jobs[0].read.bw_bytes|tostring) +
        " mean_ns=" + (.jobs[0].read.clat_ns.mean|tostring) +
        " p99_ns=" + (.jobs[0].read.clat_ns.percentile["99.000000"]|tostring)' "$result"
done
