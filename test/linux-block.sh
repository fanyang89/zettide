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
sudo -n "$probe" write "$loop"

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
