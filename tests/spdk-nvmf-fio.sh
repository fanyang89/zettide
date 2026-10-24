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
[[ $transport == tcp ]] || { echo "only NVMe/TCP is supported" >&2; exit 2; }
[[ ${ZETTIDE_SPDK_FRONTEND:-nvmf} == nvmf ]] || { echo "retired SPDK frontend" >&2; exit 2; }
target_addr=${ZETTIDE_NVMF_TARGET_ADDR:-127.0.0.1}
target_port=${ZETTIDE_NVMF_TARGET_PORT:-44220}
target_pid=""
device=""
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
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$log_dir"
rm -f "$ready_file"
nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
modprobe nvme-tcp
"$target" "$ready_file" "${target_arguments[@]}" >"$log_dir/target.log" 2>&1 &
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
