#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
fsx=${3:-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

[[ -x "$fsx" ]] || {
    external_suite=fsx
    external_mode=$mode
    external_skip_or_fail "fsx binary was not built"
}

external_initialize fsx "$mode" "$exe" 256MiB
external_start_mount

operations=${DEVDRIVE_FSX_OPS:-10000}
run_fsx() {
    local profile=$1
    local seed=$2
    shift 2
    timeout 600 "$fsx" \
        -S "$seed" \
        -N "$operations" \
        -l 16m \
        -o 64k \
        "$@" -a -T \
        -F -K -u -H -z -Y -C -I -J -B -E -0 \
        "$external_mount_dir/fsx-$profile-$seed.data"
}

for seed in 0x5eed1234 0xc0ffee; do
    run_fsx buffered "$seed" -R -W
    run_fsx mmap "$seed"
done

external_stop_mount
