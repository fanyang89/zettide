#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
test_binary=${3:-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

[[ -x "$test_binary" ]] || {
    external_suite=libfuse
    external_mode=$mode
    external_skip_or_fail "syscall test binary was not built"
}
if [[ $EUID -eq 0 ]]; then
    external_suite=libfuse
    external_mode=$mode
    external_skip_or_fail "tests must run as a non-root user"
fi

external_initialize libfuse "$mode" "$exe" 256MiB
external_start_mount

run_case() {
    local case_number=$1
    local output
    if ! output=$(timeout 30 "$test_binary" "$external_mount_dir" "$case_number" 2>&1); then
        printf '%s\n' "$output" >&2
        echo "libfuse syscall case $case_number failed" >&2
        return 1
    fi
    if [[ -z "$output" ]]; then
        echo "libfuse syscall case $case_number did not execute; generated feature numbering changed" >&2
        return 1
    fi
    printf '%s\n' "$output"
}

while IFS=$'\t' read -r classification cases _; do
    [[ -n "$classification" && ${classification:0:1} != "#" ]] || continue
    [[ "$classification" == required ]] || continue
    if [[ "$cases" == *-* ]]; then
        first=${cases%-*}
        last=${cases#*-}
        for ((case_number = first; case_number <= last; case_number++)); do
            run_case "$case_number"
        done
    else
        run_case "$cases"
    fi
done <"$script_dir/libfuse-cases.tsv"

external_stop_mount
