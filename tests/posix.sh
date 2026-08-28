#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
probe=${3:-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/external/common.sh"

[[ -x "$probe" ]] || {
    external_suite=posix
    external_mode=$mode
    external_skip_or_fail "POSIX probe was not built"
}

external_initialize posix "$mode" "$exe" 256MiB
external_start_mount
"$probe" "$external_mount_dir"
external_stop_mount
