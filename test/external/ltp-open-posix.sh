#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

external_suite=ltp-open-posix
external_mode=$mode
external_initialize ltp-open-posix "$mode" "$exe" 512MiB
external_validate_manifest "$script_dir/ltp-open-posix-cases.tsv"

source_root=${DEVDRIVE_EXTERNAL_ROOT:-"$script_dir/.prepared"}/ltp
external_verify_pin "$source_root" 6a60ae592cd375f004df0694efc7d50ddae9aa5e
binary_root="$source_root/.devdrive-bin"
[[ -d "$binary_root" ]] || external_skip_or_fail "LTP Open POSIX cases are not built; run test/external/prepare.sh"

external_start_mount
mkdir "$external_mount_dir/ltp"
while IFS=$'\t' read -r classification case_name contract reason extra; do
    [[ -n "$classification" && ${classification:0:1} != "#" ]] || continue
    [[ "$classification" == required ]] || continue
    binary_name=${case_name//\//_}
    [[ -x "$binary_root/$binary_name" ]] || external_skip_or_fail "prepared LTP binary is missing: $binary_name"
    printf 'RUN LTP Open POSIX %s (%s)\n' "$case_name" "$contract"
    TMPDIR="$external_mount_dir/ltp" timeout 60 "$binary_root/$binary_name"
done <"$script_dir/ltp-open-posix-cases.tsv"
external_stop_mount
