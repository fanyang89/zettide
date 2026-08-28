#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

external_suite=fio
external_mode=$mode
[[ "$mode" != off ]] || { echo "fio tests disabled"; exit 0; }

fio_command=${ZETTIDE_FIO:-fio}
if [[ "$fio_command" == */* ]]; then
    [[ -x "$fio_command" ]] || external_skip_or_fail "fio is unavailable: $fio_command"
    fio=$fio_command
else
    fio=$(command -v "$fio_command") || external_skip_or_fail "fio is unavailable"
fi

job_file="$script_dir/fio-verify.fio"
[[ -r "$job_file" ]] || external_skip_or_fail "fio job is unavailable: $job_file"

external_initialize fio "$mode" "$exe" 1GiB
external_start_mount

fio_data_dir="$external_mount_dir/fio-data"
fio_log_dir=${ZETTIDE_TEST_LOG_DIR:-$external_tmp}
fio_aux_dir="$fio_log_dir/fio-aux"
mkdir "$fio_data_dir"
mkdir -p "$fio_aux_dir"

# Ubuntu 24.04 ships fio 3.36, which predates verify_header_seed. Older fio
# versions do not validate that field, so omit only the unsupported option.
effective_job_file=$job_file
if ! "$fio" --cmdhelp=verify_header_seed 2>&1 | grep -q 'verify_header_seed:'; then
    effective_job_file="$fio_aux_dir/fio-verify.compat.fio"
    grep -v '^verify_header_seed=' "$job_file" >"$effective_job_file"
fi

run_fio() {
    local phase=$1
    local allow_file_create=$2
    local verify_header_seed=$3
    shift 3
    FIO_DIR="$fio_data_dir" FIO_ALLOW_FILE_CREATE="$allow_file_create" \
        FIO_VERIFY_HEADER_SEED="$verify_header_seed" \
        timeout --kill-after=30s 1800s \
        "$fio" --aux-path="$fio_aux_dir" "$@" "$effective_job_file" \
        2>&1 | tee "$fio_log_dir/fio-$phase.log"
}

save_mount_log() {
    local phase=$1
    [[ ! -s "$external_mount_log" ]] ||
        cp "$external_mount_log" "$fio_log_dir/fio-$phase-mount.log"
}

run_fio live 1 1
external_stop_mount
save_mount_log live
timeout --kill-after=10s 300s "$external_exe" check "$external_image"

external_start_mount
# A separate verify-only process does not replay random-write buffer seeds in
# the original order; CRC32C, block headers, and offsets remain verified.
run_fio remount 0 0 --verify_only=1
external_stop_mount
save_mount_log remount
