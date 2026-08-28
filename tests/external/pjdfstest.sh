#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

external_suite=pjdfstest
external_mode=$mode
[[ "$mode" != off ]] || { echo "pjdfstest tests disabled"; exit 0; }
external_require_root "$@"
external_initialize pjdfstest "$mode" "$exe" 512MiB
external_require_identity_switch
external_validate_manifest "$script_dir/pjdfstest-cases.tsv"

source_root=${ZETTIDE_EXTERNAL_ROOT:-"$script_dir/.prepared"}/pjdfstest
external_verify_pin "$source_root" ededbeb2b44929972898afb87474b0937f78a877
[[ -x "$source_root/pjdfstest" ]] || external_skip_or_fail "pjdfstest is not built; run tests/external/prepare.sh"
command -v prove >/dev/null || external_skip_or_fail "prove is unavailable"
command -v openssl >/dev/null || external_skip_or_fail "openssl is unavailable"

ZETTIDE_ALLOW_OTHER=1
external_start_mount
while IFS=$'\t' read -r classification case_name contract reason extra; do
    [[ -n "$classification" && ${classification:0:1} != "#" ]] || continue
    [[ "$classification" == required ]] || continue
    printf 'RUN pjdfstest %s (%s)\n' "$case_name" "$contract"
    (
        cd "$external_mount_dir"
        timeout 180 prove -v "$source_root/$case_name"
    )
done <"$script_dir/pjdfstest-cases.tsv"
external_stop_mount
