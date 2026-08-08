#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "usage: spdk-nvmf-fio.sh TARGET READY_FILE LOG_DIR" >&2
    exit 2
}

target=$1
ready_file=$2
log_dir=$3
runtime=${ZETTIDE_NVMF_FIO_RUNTIME:-20}
ramp_time=${ZETTIDE_NVMF_FIO_RAMP_TIME:-5}
nqn=nqn.2026-08.io.zettide:benchmark
serial=ZETTIDEBENCH000001
target_pid=""
device=""

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
    trap - EXIT INT TERM
    set +e
    nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
    if [[ -n $target_pid ]] && kill -0 "$target_pid" 2>/dev/null; then
        kill -TERM "$target_pid"
        wait "$target_pid" || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$log_dir"
rm -f "$ready_file"
modprobe nvme-tcp
nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
"$target" "$ready_file" >"$log_dir/target.log" 2>&1 &
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
    echo "NVMe-oF benchmark target did not become ready" >&2
    exit 1
}

nvme connect -t tcp -a 127.0.0.1 -s 44220 -n "$nqn"
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
[[ $(blockdev --getsize64 "$device") -eq $((64 * 1024 * 1024 * 1024)) ]]

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
}

run_case seq-read-1m-qd32-j1 read 1m 32 1 8G
run_case randread-4k-qd1-j1 randread 4k 1 1 8G
run_case randread-4k-qd32-j1 randread 4k 32 1 8G
run_case randread-4k-qd32-j4 randread 4k 32 4 8G

for result in "$log_dir"/fio-*.json; do
    jq -r '(.jobs[0].jobname) + " iops=" + (.jobs[0].read.iops|tostring) +
        " bw_bytes=" + (.jobs[0].read.bw_bytes|tostring) +
        " mean_ns=" + (.jobs[0].read.clat_ns.mean|tostring) +
        " p99_ns=" + (.jobs[0].read.clat_ns.percentile["99.000000"]|tostring)' "$result"
done
