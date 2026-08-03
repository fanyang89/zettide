#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"
ZETTIDE_MOUNT_METRICS=1

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
external_initialize fio-throughput "$mode" "$exe" 8GiB

fio_log_dir=${ZETTIDE_TEST_LOG_DIR:-$external_tmp}
fio_data_dir="$external_mount_dir/throughput-data"
baseline_file="$external_tmp/host-baseline.bin"
single_size=${ZETTIDE_THROUGHPUT_SINGLE_SIZE:-2G}
multi_size=${ZETTIDE_THROUGHPUT_MULTI_SIZE:-512M}
runtime=${ZETTIDE_THROUGHPUT_RUNTIME:-15}
ramp_time=${ZETTIDE_THROUGHPUT_RAMP_TIME:-2}
monitor_pids=()
perf_data=
mkdir -p "$fio_log_dir"

drop_caches() {
    sync
    printf '3\n' >/proc/sys/vm/drop_caches
}

run_host() {
    local phase=$1
    local rw=$2
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
        --time_based=1 \
        --runtime="$runtime" \
        --ramp_time="$ramp_time" \
        --output-format=json \
        --output="$fio_log_dir/host-$phase.json"
}

run_zettide() {
    local phase=$1
    local rw=$2
    local allow_file_create=$3
    local start_ns end_ns status
    start_monitors "$phase"
    start_ns=$(date +%s%N)
    set +e
    FIO_DIR="$fio_data_dir" \
        FIO_RW="$rw" \
        FIO_ALLOW_FILE_CREATE="$allow_file_create" \
        FIO_SINGLE_SIZE="$single_size" \
        FIO_MULTI_SIZE="$multi_size" \
        FIO_RUNTIME="$runtime" \
        FIO_RAMP_TIME="$ramp_time" \
        "$fio" \
        --output-format=json \
        --output="$fio_log_dir/zettide-$phase.json" \
        "$job_file"
    status=$?
    set -e
    end_ns=$(date +%s%N)
    stop_monitors
    printf 'wall_time_ns=%s\n' "$((end_ns - start_ns))" \
        >"$fio_log_dir/zettide-$phase.time"
    return "$status"
}

start_monitors() {
    local phase=$1
    timeout 180s iostat -dx 1 >"$fio_log_dir/zettide-$phase-iostat.log" &
    monitor_pids+=("$!")
    timeout 180s pidstat -dru -p "$external_mount_pid" 1 \
        >"$fio_log_dir/zettide-$phase-pidstat.log" &
    monitor_pids+=("$!")
    if command -v perf >/dev/null; then
        perf_data="$fio_log_dir/zettide-$phase-perf.data"
        perf record --quiet -F 99 --call-graph fp \
            --pid "$external_mount_pid" --output "$perf_data" -- sleep 180 &
        monitor_pids+=("$!")
    fi
}

stop_monitors() {
    local pid
    for pid in "${monitor_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    monitor_pids=()
    if [[ -n "$perf_data" && -s "$perf_data" ]]; then
        perf report --stdio --no-children --sort dso,symbol \
            --input "$perf_data" >"${perf_data%.data}-report.txt" || true
    fi
    perf_data=
}

echo "Running direct host filesystem baseline"
run_host write write
drop_caches
run_host read read
rm -f "$baseline_file"

external_start_mount
mkdir "$fio_data_dir"
echo "Running Zettide sequential writes"
run_zettide write write 1
external_stop_mount
[[ ! -s "$external_mount_log" ]] || cp "$external_mount_log" "$fio_log_dir/zettide-write-mount.log"
timeout --kill-after=10s 300s "$external_exe" check "$external_image" \
    >"$fio_log_dir/zettide-check.log" 2>&1

drop_caches
external_start_mount
echo "Running cold Zettide sequential reads"
run_zettide read read 0
external_stop_mount
[[ ! -s "$external_mount_log" ]] || cp "$external_mount_log" "$fio_log_dir/zettide-read-mount.log"
