#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/common.sh"

external_suite=xfstests
external_mode=$mode
[[ "$mode" != off ]] || { echo "xfstests tests disabled"; exit 0; }
external_require_root "$@"
external_initialize xfstests "$mode" "$exe" 1GiB
external_validate_manifest "$script_dir/xfstests-cases.tsv"
command -v findmnt >/dev/null || external_skip_or_fail "findmnt is unavailable"

source_root=${DEVDRIVE_EXTERNAL_ROOT:-"$script_dir/.prepared"}/xfstests
external_verify_pin "$source_root" acb6d4cb84205a8e3f19ca470cfcf7bf6d93a509
[[ -x "$source_root/check" && -x "$source_root/src/locktest" && -x "$source_root/src/t_ofd_locks" ]] || \
    external_skip_or_fail "xfstests is not built; run test/external/prepare.sh"

config="$external_tmp/xfstests.config"
results="$external_tmp/xfstests-results"

failures=0
while IFS=$'\t' read -r classification case_name contract reason extra; do
    [[ -n "$classification" && ${classification:0:1} != "#" ]] || continue
    [[ "$classification" == required ]] || continue
    printf 'RUN xfstests %s (%s)\n' "$case_name" "$contract"
    external_start_mount
    test_source=$(findmnt -n -o SOURCE --target "$external_mount_dir")
    cat >"$config" <<EOF
export FSTYP=fuse
export TEST_DEV='$test_source'
export TEST_DIR='$external_mount_dir'
export RESULT_BASE='$results'
EOF
    rm -rf "$results"
    set +e
    (
        cd "$source_root"
        HOST_OPTIONS="$config" timeout 300 ./check "$case_name"
    )
    case_status=$?
    set -e
    if [[ -e "$results/$case_name.notrun" ]]; then
        echo "required xfstests case did not run: $case_name" >&2
        case_status=1
    fi
    if [[ -n ${DEVDRIVE_TEST_LOG_DIR:-} && -d "$results" ]]; then
        archive="$DEVDRIVE_TEST_LOG_DIR/xfstests-${case_name//\//-}"
        rm -rf "$archive"
        cp -a "$results" "$archive"
    fi
    ((case_status == 0)) || failures=1
    if mountpoint -q "$external_mount_dir"; then
        external_stop_mount
    else
        wait "$external_mount_pid" 2>/dev/null || true
        external_mount_pid=
    fi
done <"$script_dir/xfstests-cases.tsv"

((failures == 0))
