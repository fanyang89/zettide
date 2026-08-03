#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

external_suite=fio-throughput
external_mode=$mode
[[ "$mode" != off ]] || { echo "fio throughput disabled"; exit 0; }

fio_command=${ZETTIDE_FIO:-fio}
if [[ "$fio_command" == */* ]]; then
    [[ -x "$fio_command" ]] || external_skip_or_fail "fio is unavailable: $fio_command"
    fio=$fio_command
else
    fio=$(command -v "$fio_command") || external_skip_or_fail "fio is unavailable"
fi

job_file="$script_dir/fio-throughput.fio"
[[ -r "$job_file" ]] || external_skip_or_fail "fio job is unavailable: $job_file"

external_require_root "$@"
external_initialize fio-throughput "$mode" "$exe" 24GiB

fio_log_dir=${ZETTIDE_TEST_LOG_DIR:-$external_tmp}
fio_data_dir="$external_mount_dir/throughput-data"
baseline_file="$external_tmp/host-baseline.bin"
single_size=${ZETTIDE_THROUGHPUT_SINGLE_SIZE:-8G}
multi_size=${ZETTIDE_THROUGHPUT_MULTI_SIZE:-2G}
mkdir -p "$fio_log_dir"

drop_caches() {
    sync
    printf '3\n' >/proc/sys/vm/drop_caches
}

run_host() {
    local phase=$1
    local rw=$2
    local sync_args=()
    [[ "$rw" != write ]] || sync_args+=(--end_fsync=1)
    "$fio" \
        --name="host-$phase" \
        --filename="$baseline_file" \
        --rw="$rw" \
        --bs=1m \
        --size="$single_size" \
        --ioengine=io_uring \
        --iodepth=32 \
        --direct=1 \
        --fallocate=none \
        --group_reporting=1 \
        --output-format=json \
        --output="$fio_log_dir/host-$phase.json" \
        "${sync_args[@]}"
}

run_zettide() {
    local phase=$1
    local rw=$2
    local allow_file_create=$3
    local end_fsync=$4
    FIO_DIR="$fio_data_dir" \
        FIO_RW="$rw" \
        FIO_ALLOW_FILE_CREATE="$allow_file_create" \
        FIO_END_FSYNC="$end_fsync" \
        FIO_SINGLE_SIZE="$single_size" \
        FIO_MULTI_SIZE="$multi_size" \
        "$fio" \
        --output-format=json \
        --output="$fio_log_dir/zettide-$phase.json" \
        "$job_file"
}

echo "Running direct host filesystem baseline"
run_host write write
drop_caches
run_host read read
rm -f "$baseline_file"

external_start_mount
mkdir "$fio_data_dir"
echo "Running Zettide sequential writes"
run_zettide write write 1 1
external_stop_mount
[[ ! -s "$external_mount_log" ]] || cp "$external_mount_log" "$fio_log_dir/zettide-write-mount.log"
timeout --kill-after=10s 300s "$external_exe" check "$external_image" \
    >"$fio_log_dir/zettide-check.log" 2>&1

drop_caches
external_start_mount
echo "Running cold Zettide sequential reads"
run_zettide read read 0 0
external_stop_mount
[[ ! -s "$external_mount_log" ]] || cp "$external_mount_log" "$fio_log_dir/zettide-read-mount.log"
