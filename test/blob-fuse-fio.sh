#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "usage: blob-fuse-fio.sh CLI TMPDIR LOG_DIR" >&2
    exit 2
}

cli=$1
target_tmpdir=$2
log_dir=$3
backing_size=${ZETTIDE_BLOB_FUSE_FIO_BACKING_SIZE:-34359738368}
file_size=${ZETTIDE_BLOB_FUSE_FIO_FILE_SIZE:-268435456}
runtime=${ZETTIDE_BLOB_FUSE_FIO_RUNTIME:-8}
ramp_time=${ZETTIDE_BLOB_FUSE_FIO_RAMP_TIME:-2}

[[ $EUID -eq 0 ]] || {
    echo "Blob FUSE fio requires root" >&2
    exit 2
}
[[ -x $cli ]] || {
    echo "Zettide CLI is not executable: $cli" >&2
    exit 2
}
[[ $target_tmpdir == /* && $target_tmpdir != / ]] || {
    echo "Blob FUSE fio tmpdir must be absolute and must not be /: $target_tmpdir" >&2
    exit 2
}
[[ $backing_size =~ ^[1-9][0-9]*$ && $file_size =~ ^[1-9][0-9]*$ && $file_size -lt $backing_size ]] || {
    echo "Blob FUSE fio sizes must be positive integer bytes with the test file smaller than the backing image" >&2
    exit 2
}
[[ $runtime =~ ^[1-9][0-9]*$ && $ramp_time =~ ^[0-9]+$ ]] || {
    echo "Blob FUSE fio runtime and ramp time must be integer seconds" >&2
    exit 2
}
for command in cat df fio flock fusermount3 grep jq mkdir mktemp mountpoint realpath rm sleep timeout; do
    command -v "$command" >/dev/null || {
        echo "$command is required for Blob FUSE fio" >&2
        exit 2
    }
done
[[ -d $target_tmpdir ]] || {
    echo "Blob FUSE fio tmpdir is not a directory: $target_tmpdir" >&2
    exit 2
}
target_tmpdir=$(realpath -e -- "$target_tmpdir")
[[ $target_tmpdir != / ]] || {
    echo "Blob FUSE fio tmpdir resolves to /" >&2
    exit 2
}
[[ -d $log_dir ]] || {
    echo "Blob FUSE fio log directory does not exist: $log_dir" >&2
    exit 2
}

available=$(df --output=avail -B1 -- "$target_tmpdir")
available=${available##*$'\n'}
available=${available//[[:space:]]/}
[[ $available =~ ^[0-9]+$ && $available -ge $backing_size ]] || {
    echo "Blob FUSE fio requires at least $backing_size bytes free in $target_tmpdir (available: $available)" >&2
    exit 2
}

work=$(mktemp -d -- "$target_tmpdir/zettide-blob-fuse-fio.XXXXXX")
mountpoint_path="$work/mount"
backing="$work/blob.ddv"
mount_pid=""
mkdir "$mountpoint_path"

stop_blob_mount() {
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
            kill -TERM -- "$mount_pid" 2>/dev/null || true
            sleep 1
        fi
        if kill -0 "$mount_pid" 2>/dev/null; then
            kill -KILL -- "$mount_pid" 2>/dev/null || true
        fi
        wait "$mount_pid" 2>/dev/null || true
        mount_pid=""
    fi
    ! mountpoint -q "$mountpoint_path"
}

finish() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if stop_blob_mount; then
        rm -rf --one-file-system -- "$work" || {
            echo "Failed to remove Blob FUSE fio work directory: $work" >&2
            result=1
        }
    else
        echo "Blob FUSE mount remains active; preserving work directory: $work" >&2
        result=1
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stop_blob_mount_clean() {
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

start_blob_mount() {
    local log=$1

    : >"$log"
    "$cli" mount "$backing" "$mountpoint_path" --noatime --metrics >"$log" 2>&1 &
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
    echo "Blob FUSE mount readiness timeout" >&2
    return 1
}

require_fuse_metrics() {
    local log=$1
    local metrics

    metrics=$(grep '^fuse_metrics ' "$log") || {
        echo "Blob FUSE mount log lacks fuse_metrics: $log" >&2
        return 1
    }
    if grep -Eq '(^| )[a-z_]+_errors=[1-9][0-9]*($| )' <<<"$metrics"; then
        echo "Blob FUSE mount reported operation errors: $log" >&2
        return 1
    fi
    if grep -Eq '^(pipeline_metrics|member_transport_metrics) ' "$log"; then
        echo "Blob FUSE mount unexpectedly printed obsolete pipeline metrics: $log" >&2
        return 1
    fi
}

run_fio_command() {
    local name=$1
    shift
    local json_log="$log_dir/fio-$name.json"
    local stderr_log="$log_dir/fio-$name.stderr.log"
    local fio_status=0
    local failed=0

    fio "$@" --output-format=json --output="$json_log" 2>"$stderr_log" || fio_status=$?

    if ! jq -e 'type == "object" and (.jobs | type == "array" and length > 0)' \
        "$json_log" >/dev/null 2>&1; then
        echo "Blob FUSE fio case $name did not produce valid fio JSON with jobs: $json_log" >&2
        return 1
    fi
    if ! jq -e 'all(.jobs[]; ((.error | type) == "number") and (.error == 0))' \
        "$json_log" >/dev/null; then
        jq -r '.jobs[] | select(.error != 0) | "Blob FUSE fio job \(.jobname // \"<unknown>\") failed with error \(.error)"' \
            "$json_log" >&2
        failed=1
    fi
    if jq -e 'any(.jobs[]; .error == 28)' "$json_log" >/dev/null ||
        grep -Eqi 'No space left on device|ENOSPC' "$stderr_log"; then
        echo "Blob FUSE fio case $name failed with ENOSPC; the COW backing image exhausted its capacity" >&2
        failed=1
    fi
    if ((fio_status != 0)); then
        echo "Blob FUSE fio case $name exited with status $fio_status" >&2
        failed=1
    fi
    ((failed == 0))
}

run_fio_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local mount_log="$log_dir/mount-$name.log"
    local status=0

    start_blob_mount "$mount_log"
    run_fio_command "$name" \
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
        --refill_buffers=1 \
        --percentile_list=50:95:99:99.9 \
        --eta=never || status=$?
    stop_blob_mount_clean || return 1
    require_fuse_metrics "$mount_log"
    return "$status"
}

[[ ! -e $backing && ! -L $backing ]] || {
    echo "Blob FUSE backing path must not exist: $backing" >&2
    exit 2
}
"$cli" format "$backing" --size "$backing_size" >"$log_dir/format.log"
[[ -f $backing && ! -L $backing ]] || {
    echo "Blob FUSE backing path is not a regular file: $backing" >&2
    exit 2
}

start_blob_mount "$log_dir/mount-prepare.log"
run_fio_command prepare \
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
    --eta=never
stop_blob_mount_clean
require_fuse_metrics "$log_dir/mount-prepare.log"

run_fio_case seq-read-1m-qd32 read 1m 32
run_fio_case randread-4k-qd1 randread 4k 1
run_fio_case randread-4k-qd32 randread 4k 32
run_fio_case seq-write-1m-qd32 write 1m 32
run_fio_case randwrite-4k-qd1 randwrite 4k 1
run_fio_case randwrite-4k-qd32 randwrite 4k 32

"$cli" check "$backing" >"$log_dir/check.log" 2>&1
echo "Blob FUSE fio passed"
