#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 4 ]] || {
    echo "usage: physical-pool-fio.sh CLI DEVICE SERIAL POOL_ID" >&2
    exit 2
}

cli=$1
device=$2
expected_serial=$3
expected_pool_id=$4
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
single_size=${ZETTIDE_POOL_FIO_SINGLE_SIZE:-2G}
multi_size=${ZETTIDE_POOL_FIO_MULTI_SIZE:-512M}
runtime=${ZETTIDE_POOL_FIO_RUNTIME:-20}
ramp_time=${ZETTIDE_POOL_FIO_RAMP_TIME:-5}

[[ $EUID -eq 0 ]] || {
    echo "physical Pool fio requires root" >&2
    exit 2
}
[[ $runtime =~ ^[1-9][0-9]*$ && $ramp_time =~ ^[0-9]+$ ]] || {
    echo "fio runtime and ramp time must be integer seconds" >&2
    exit 2
}
for command in fio fusermount3 lsblk mountpoint setsid timeout; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done

mkdir -p "$log_dir"
work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-physical-pool-fio.XXXXXX")
mountpoint_path="$work/mount"
mkdir "$mountpoint_path"
mount_pid=""

check_identity() {
    local actual_type actual_serial
    actual_type=$(lsblk --nodeps --noheadings --output TYPE "$device" | tr -d '[:space:]')
    actual_serial=$(lsblk --nodeps --noheadings --output SERIAL "$device" | tr -d '[:space:]')
    [[ $actual_type == disk && $actual_serial == "$expected_serial" ]] || {
        echo "physical Pool identity changed: $device ($actual_type, $actual_serial)" >&2
        return 1
    }
}

stop_pool_mount() {
    if mountpoint -q "$mountpoint_path"; then
        timeout --kill-after=2s 30s "$cli" unmount "$mountpoint_path" >/dev/null 2>&1 ||
            timeout --kill-after=2s 10s fusermount3 -uz "$mountpoint_path" >/dev/null 2>&1 || true
    fi
    if [[ -n $mount_pid ]]; then
        for ((attempt = 0; attempt < 300; attempt++)); do
            kill -0 "$mount_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$mount_pid" 2>/dev/null; then
            kill -TERM -- "-$mount_pid" 2>/dev/null || true
            sleep 1
        fi
        if kill -0 "$mount_pid" 2>/dev/null; then
            kill -KILL -- "-$mount_pid" 2>/dev/null || true
        fi
        wait "$mount_pid" 2>/dev/null || true
        mount_pid=""
    fi
    ! mountpoint -q "$mountpoint_path"
}

stop_pool_mount_clean() {
    mountpoint -q "$mountpoint_path" || return 1
    timeout --kill-after=2s 30s "$cli" unmount "$mountpoint_path" >/dev/null
    for ((attempt = 0; attempt < 300; attempt++)); do
        kill -0 "$mount_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$mount_pid" 2>/dev/null && return 1
    wait "$mount_pid"
    mount_pid=""
    ! mountpoint -q "$mountpoint_path"
}

start_pool_mount() {
    local log=$1
    shift
    : >"$log"
    setsid "$cli" pool mount "$mountpoint_path" --device "$device" --allow-other --noatime "$@" \
        >"$log" 2>&1 &
    mount_pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        if mountpoint -q "$mountpoint_path"; then
            return
        fi
        if ! kill -0 "$mount_pid" 2>/dev/null; then
            cat "$log" >&2
            return 1
        fi
        sleep 0.1
    done
    cat "$log" >&2
    echo "physical Pool mount readiness timeout" >&2
    return 1
}

finish() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    stop_pool_mount || result=1
    rm -rf "$work"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT TERM

run_fio_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local jobs=$5
    local size=$6
    local file_pattern=$7
    local mount_log="$log_dir/mount-$name.log"
    local -a fio_args=(
        fio
        --name="$name"
        --rw="$rw"
        --bs="$block_size"
        --size="$size"
        --ioengine=io_uring
        --iodepth="$depth"
        --numjobs="$jobs"
        --direct=1
        --fallocate=none
        --allow_file_create=0
        --invalidate=1
        --group_reporting=1
        --time_based=1
        --runtime="$runtime"
        --ramp_time="$ramp_time"
        --randrepeat=0
        --norandommap=1
        --refill_buffers=1
        --percentile_list=50:95:99:99.9
        --eta=never
        --output-format=json
        --output="$log_dir/fio-$name.json"
    )
    start_pool_mount "$mount_log" --metrics
    if [[ $jobs -eq 1 ]]; then
        fio_args+=(--filename="$mountpoint_path/fio-performance/$file_pattern")
    else
        fio_args+=(--filename_format="$mountpoint_path/fio-performance/$file_pattern")
    fi
    "${fio_args[@]}"
    stop_pool_mount_clean
    grep -q '^fuse_metrics ' "$mount_log"
    grep -q '^pipeline_metrics ' "$mount_log"
    grep -q '^member_transport_metrics index=0 ' "$mount_log"
}

prepare_single_file() {
    fio \
        --name=prepare-single \
        --filename="$fio_dir/single.bin" \
        --rw=write \
        --bs=1m \
        --size="$single_size" \
        --ioengine=io_uring \
        --iodepth=32 \
        --direct=1 \
        --fallocate=none \
        --end_fsync=1 \
        --group_reporting=1 \
        --eta=never \
        --output-format=json \
        --output="$log_dir/fio-prepare-single.json"
}

prepare_multi_files() {
    fio \
        --name=prepare-multi \
        --filename_format="$fio_dir/multi.\$jobnum.bin" \
        --numjobs=4 \
        --rw=write \
        --bs=1m \
        --size="$multi_size" \
        --ioengine=io_uring \
        --iodepth=32 \
        --direct=1 \
        --fallocate=none \
        --end_fsync=1 \
        --group_reporting=1 \
        --eta=never \
        --output-format=json \
        --output="$log_dir/fio-prepare-multi.json"
}

check_identity
"$cli" device inspect "$device" >"$log_dir/device-inspect.log"
grep -q '^Preflight: eligible$' "$log_dir/device-inspect.log"
"$cli" pool inspect --device "$device" >"$log_dir/pool-inspect-before.log"
grep -q "^Pool: $expected_pool_id$" "$log_dir/pool-inspect-before.log"
grep -q '^Profile: unprotected$' "$log_dir/pool-inspect-before.log"
grep -q '^Data policy: read_write$' "$log_dir/pool-inspect-before.log"
grep -q '^Mountable: yes$' "$log_dir/pool-inspect-before.log"

start_pool_mount "$log_dir/mount-prepare.log"
fio_dir="$mountpoint_path/fio-performance"
mkdir -p "$fio_dir"
[[ -f $fio_dir/single.bin ]] || prepare_single_file
multi_ready=true
for job in 0 1 2 3; do
    [[ -f $fio_dir/multi.$job.bin ]] || multi_ready=false
done
[[ $multi_ready == true ]] || prepare_multi_files
stop_pool_mount_clean

run_fio_case seq-write-1m-qd32-j1 write 1m 32 1 "$single_size" single.bin
run_fio_case randwrite-4k-qd1-j1 randwrite 4k 1 1 "$single_size" single.bin
run_fio_case randwrite-4k-qd32-j1 randwrite 4k 32 1 "$single_size" single.bin
run_fio_case randwrite-4k-qd32-j4 randwrite 4k 32 4 "$multi_size" 'multi.$jobnum.bin'
run_fio_case seq-read-1m-qd32-j1 read 1m 32 1 "$single_size" single.bin
run_fio_case randread-4k-qd1-j1 randread 4k 1 1 "$single_size" single.bin
run_fio_case randread-4k-qd32-j1 randread 4k 32 1 "$single_size" single.bin
run_fio_case randread-4k-qd32-j4 randread 4k 32 4 "$multi_size" 'multi.$jobnum.bin'

check_identity
"$cli" pool inspect --device "$device" >"$log_dir/pool-inspect-after.log"
grep -q "^Pool: $expected_pool_id$" "$log_dir/pool-inspect-after.log"
grep -q '^Mountable: yes$' "$log_dir/pool-inspect-after.log"
echo "physical Pool fio passed"
