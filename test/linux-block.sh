#!/usr/bin/env bash
set -euo pipefail

mode=$1

if [[ "$mode" == "off" ]]; then
    echo "linux block tests disabled"
    exit 0
fi

skip_or_fail() {
    if [[ "$mode" == "required" ]]; then
        echo "$1" >&2
        exit 1
    fi
    echo "linux block tests skipped: $1"
    exit 0
}

[[ $# -ge 3 ]] || skip_or_fail "Linux target is required"
probe=$2
cli=$3
[[ "$(uname -s)" == "Linux" ]] || skip_or_fail "Linux is required"
command -v losetup >/dev/null || skip_or_fail "losetup is unavailable"
command -v truncate >/dev/null || skip_or_fail "truncate is unavailable"
command -v blockdev >/dev/null || skip_or_fail "blockdev is unavailable"
command -v mkfs.ext4 >/dev/null || skip_or_fail "mkfs.ext4 is unavailable"
command -v mount >/dev/null || skip_or_fail "mount is unavailable"
command -v umount >/dev/null || skip_or_fail "umount is unavailable"
sudo -n true 2>/dev/null || skip_or_fail "passwordless sudo is unavailable"

work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-block.XXXXXX")
loop=""
mounted=false
cleanup() {
    if [[ "$mounted" == "true" ]]; then
        sudo -n umount "$work/mount" || true
    fi
    if [[ -n "$loop" ]]; then
        sudo -n losetup --detach "$loop" || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

truncate --size 32MiB "$work/backing"
loop=$(sudo -n losetup --find --show "$work/backing") || skip_or_fail "no loop device is available"
sudo -n "$cli" device inspect "$loop" | grep -q '^Preflight: eligible$'
stale_plan=$(sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected --label loop-cli)
stale_token=$(grep '^Confirm token: ' <<<"$stale_plan")
stale_token=${stale_token#Confirm token: }
original_loop=$loop
sudo -n losetup --detach "$loop"
loop=""
truncate --size 32MiB "$work/replacement"
sudo -n losetup "$original_loop" "$work/replacement"
loop=$original_loop
if sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli --confirm "$stale_token" >/dev/null 2>&1; then
    echo "stale device-instance token was accepted" >&2
    exit 1
fi
sudo -n losetup --detach "$loop"
loop=""
sudo -n losetup "$original_loop" "$work/backing"
loop=$original_loop
printf '\001' | sudo -n dd of="$loop" bs=1 seek=$((16 * 1024 * 1024)) conv=notrunc status=none
sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected \
    | grep -q '^Status: contains data$'
printf '\000' | sudo -n dd of="$loop" bs=1 seek=$((16 * 1024 * 1024)) conv=notrunc status=none
plan=$(sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected --label loop-cli)
grep -q '^Plan: ready$' <<<"$plan"
token=$(grep '^Confirm token: ' <<<"$plan")
token=${token#Confirm token: }
if sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli --confirm invalid >/dev/null 2>&1; then
    echo "invalid confirmation token was accepted" >&2
    exit 1
fi
sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli --confirm "$token" \
    | grep -q '^Created pool: '
sudo -n "$probe" reopen "$loop"
sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected \
    | grep -q '^Status: contains data$'

sudo -n blockdev --setro "$loop"
sudo -n "$cli" device inspect "$loop" | grep -q '^Preflight: rejected$'
sudo -n "$probe" expect-read-only "$loop"
sudo -n blockdev --setrw "$loop"

sudo -n mkfs.ext4 -q -F "$loop"
mkdir "$work/mount"
sudo -n mount "$loop" "$work/mount"
mounted=true
sudo -n "$cli" device inspect "$loop" | grep -q '^Reasons: mounted$'
sudo -n "$probe" expect-mounted "$loop"
sudo -n umount "$work/mount"
mounted=false
