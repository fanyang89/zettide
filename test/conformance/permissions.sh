#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
probe=${3:-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/../external/common.sh"

external_suite=permissions
external_mode=$mode
[[ -x "$probe" ]] || external_skip_or_fail "permission probe was not built"
external_require_root "$@"
external_initialize permissions "$mode" "$exe" 256MiB
external_require_identity_switch
ZETTIDE_ALLOW_OTHER=1
external_start_mount
timeout 60 "$probe" "$external_mount_dir"
external_stop_mount
