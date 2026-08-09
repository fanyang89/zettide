#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 5 ]] || {
    echo "usage: scheduled-blob-pool-fuse-fio.sh CLI POOL_ID DEVICE DEVICE DEVICE" >&2
    exit 2
}

cli=$1
pool_id=$2
devices=("$3" "$4" "$5")
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
runtime=${ZETTIDE_SCHEDULED_BLOB_POOL_FIO_RUNTIME:-20}
ramp_time=${ZETTIDE_SCHEDULED_BLOB_POOL_FIO_RAMP_TIME:-5}
file_size=2G

[[ $EUID -eq 0 ]] || {
    echo "scheduled Blob Pool FUSE fio requires root" >&2
    exit 2
}
[[ -x $cli ]] || {
    echo "Zettide CLI is not executable: $cli" >&2
    exit 2
}
[[ $pool_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "scheduled Blob Pool ID must be 32 lowercase hexadecimal digits" >&2
    exit 2
}
[[ $runtime =~ ^[1-9][0-9]*$ && $ramp_time =~ ^[0-9]+$ ]] || {
    echo "scheduled fio runtime and ramp time must be integer seconds" >&2
    exit 2
}
for command in cat fio fusermount3 grep jq mkdir mktemp mountpoint rm setsid sleep stat timeout; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done
[[ -d $log_dir ]] || {
    echo "scheduled fio log directory does not exist: $log_dir" >&2
    exit 2
}
declare -A device_ids=()
device_args=()
for device in "${devices[@]}"; do
    [[ -b $device && -w $device ]] || {
        echo "scheduled Pool member is not a writable block device: $device" >&2
        exit 2
    }
    device_id=$(stat --format='%t:%T' "$device")
    [[ -z ${device_ids[$device_id]+present} ]] || {
        echo "scheduled Pool member is duplicated: $device" >&2
        exit 2
    }
    device_ids[$device_id]=$device
    device_args+=(--device "$device")
done
[[ ${#device_ids[@]} -eq 3 ]]

cat >"$log_dir/benchmark-metadata.log" <<EOF
profile=scheduled-blob-pool-fio
source_profile=synthetic-single-physical-device
description=synthetic scheduled Pool on one physical device
physical_device_count=1
synthetic_member_count=3
pool_id=$pool_id
file_size=$file_size
runtime=$runtime
ramp_time=$ramp_time
seq_read_128k_scheduler_batch=32x4096
EOF

"$cli" pool inspect "${device_args[@]}" >"$log_dir/pool-inspect-before-fio.log"
grep -q "^Pool: $pool_id$" "$log_dir/pool-inspect-before-fio.log"
grep -q '^Filesystem: blob$' "$log_dir/pool-inspect-before-fio.log"
grep -q '^Profile: scheduled-replicated$' "$log_dir/pool-inspect-before-fio.log"
grep -q '^Members: 3/3$' "$log_dir/pool-inspect-before-fio.log"
grep -q '^Data policy: read_write$' "$log_dir/pool-inspect-before-fio.log"
grep -q '^Mountable: yes$' "$log_dir/pool-inspect-before-fio.log"

work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-scheduled-blob-pool-fio.XXXXXX")
mountpoint_path="$work/mount"
mkdir "$mountpoint_path"
mount_pid=""

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

finish() {
    local result=$?
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    if stop_pool_mount; then
        rm -rf --one-file-system -- "$work" || result=1
    else
        echo "scheduled Blob Pool mount remains active; preserving $work" >&2
        result=1
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

start_pool_mount() {
    local log=$1
    : >"$log"
    setsid "$cli" pool mount "$mountpoint_path" "${device_args[@]}" \
        --allow-other --noatime --metrics >"$log" 2>&1 &
    mount_pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        if mountpoint -q "$mountpoint_path"; then
            return
        fi
        if ! kill -0 "$mount_pid" 2>/dev/null; then
            wait "$mount_pid" 2>/dev/null || true
            mount_pid=""
            echo "scheduled Blob Pool mount exited before readiness: $log" >&2
            return 1
        fi
        sleep 0.1
    done
    echo "scheduled Blob Pool mount readiness timeout: $log" >&2
    return 1
}

stop_pool_mount_clean() {
    mountpoint -q "$mountpoint_path" || return 1
    timeout --kill-after=2s 30s "$cli" unmount "$mountpoint_path" >/dev/null || return 1
    for ((attempt = 0; attempt < 300; attempt++)); do
        kill -0 "$mount_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$mount_pid" 2>/dev/null && return 1
    if ! wait "$mount_pid"; then
        mount_pid=""
        return 1
    fi
    mount_pid=""
    ! mountpoint -q "$mountpoint_path"
}

require_metrics() {
    local log=$1
    local activity=$2
    local require_parallel=$3
    local fuse_calls submitted completions current_inflight max_inflight
    local -a fuse_lines pool_lines

    mapfile -t fuse_lines < <(grep '^fuse_metrics ' "$log")
    mapfile -t pool_lines < <(grep '^pool_transport_metrics ' "$log")
    [[ ${#fuse_lines[@]} -eq 1 && ${#pool_lines[@]} -eq 1 ]] || {
        echo "scheduled mount log must contain one FUSE and one Pool metric line: $log" >&2
        return 1
    }
    ! grep -Eq '^(pipeline_metrics|member_transport_metrics) ' "$log" || {
        echo "scheduled Blob Pool emitted unexpected LittleFS or member metrics: $log" >&2
        return 1
    }
    if grep -Eq '(^| )[a-z_]+_errors=[1-9][0-9]*($| )' <<<"${fuse_lines[0]}"; then
        echo "scheduled FUSE mount reported operation errors: $log" >&2
        return 1
    fi
    [[ ${fuse_lines[0]} =~ ${activity}_calls=([0-9]+) ]]
    fuse_calls=${BASH_REMATCH[1]}
    ((fuse_calls > 0)) || {
        echo "scheduled FUSE mount reported no $activity calls: $log" >&2
        return 1
    }
    [[ ${pool_lines[0]} =~ submitted_sqes=([0-9]+) ]]
    submitted=${BASH_REMATCH[1]}
    [[ ${pool_lines[0]} =~ completions=([0-9]+) ]]
    completions=${BASH_REMATCH[1]}
    [[ ${pool_lines[0]} =~ current_inflight=([0-9]+) ]]
    current_inflight=${BASH_REMATCH[1]}
    [[ ${pool_lines[0]} =~ max_inflight=([0-9]+) ]]
    max_inflight=${BASH_REMATCH[1]}
    ((submitted > 0 && submitted == completions && current_inflight == 0)) || {
        echo "scheduled Pool transport metrics are not drained: $log" >&2
        return 1
    }
    if [[ $require_parallel == true ]]; then
        ((max_inflight > 1)) || {
            echo "scheduled read did not exercise parallel Pool transport: $log" >&2
            return 1
        }
    fi
}

run_fio_command() {
    local name=$1
    shift
    local json_log="$log_dir/fio-$name.json"
    local stderr_log="$log_dir/fio-$name.stderr.log"
    local fio_status=0 failed=0

    fio "$@" --output-format=json --output="$json_log" 2>"$stderr_log" || fio_status=$?
    if ! jq -e 'type == "object" and (.jobs | type == "array" and length > 0)' \
        "$json_log" >/dev/null 2>&1; then
        echo "scheduled fio case $name did not produce valid JSON: $json_log" >&2
        return 1
    fi
    if ! jq -e 'all(.jobs[]; ((.error | type) == "number") and (.error == 0))' \
        "$json_log" >/dev/null; then
        failed=1
    fi
    if ((fio_status != 0)); then
        echo "scheduled fio case $name exited with status $fio_status" >&2
        failed=1
    fi
    ((failed == 0))
}

run_fio_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local require_parallel=$5
    local mount_log="$log_dir/mount-$name.log"
    local status=0

    start_pool_mount "$mount_log"
    if ! run_fio_command "$name" \
        --name="$name" \
        --filename="$mountpoint_path/test.bin" \
        --rw="$rw" \
        --bs="$block_size" \
        --size="$file_size" \
        --ioengine=io_uring \
        --iodepth="$depth" \
        --numjobs=1 \
        --direct=1 \
        --fallocate=none \
        --allow_file_create=0 \
        --invalidate=1 \
        --group_reporting=1 \
        --time_based=1 \
        --runtime="$runtime" \
        --ramp_time="$ramp_time" \
        --randrepeat=0 \
        --norandommap=1 \
        --percentile_list=50:95:99:99.9 \
        --eta=never; then
        status=1
    fi
    stop_pool_mount_clean || status=1
    require_metrics "$mount_log" read "$require_parallel" || status=1
    return "$status"
}

start_pool_mount "$log_dir/mount-prepare.log"
if ! run_fio_command prepare \
    --name=prepare \
    --filename="$mountpoint_path/test.bin" \
    --rw=write \
    --bs=1m \
    --size="$file_size" \
    --ioengine=io_uring \
    --iodepth=32 \
    --numjobs=1 \
    --direct=1 \
    --fallocate=none \
    --end_fsync=1 \
    --group_reporting=1 \
    --eta=never; then
    exit 1
fi
stop_pool_mount_clean
require_metrics "$log_dir/mount-prepare.log" write false

run_fio_case seq-read-1m-qd32-j1 read 1m 32 true
run_fio_case seq-read-128k-qd1-j1 read 128k 1 true
run_fio_case randread-4k-qd1-j1 randread 4k 1 false
run_fio_case randread-4k-qd32-j1 randread 4k 32 false

"$cli" pool inspect "${device_args[@]}" >"$log_dir/pool-inspect-after-fio.log"
grep -q "^Pool: $pool_id$" "$log_dir/pool-inspect-after-fio.log"
grep -q '^Data policy: read_write$' "$log_dir/pool-inspect-after-fio.log"
grep -q '^Mountable: yes$' "$log_dir/pool-inspect-after-fio.log"
echo "synthetic single-device scheduled Blob Pool FUSE read fio passed"
