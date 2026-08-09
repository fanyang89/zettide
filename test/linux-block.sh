#!/usr/bin/env bash
set -euo pipefail

mode=$1
[[ "$mode" != off ]] || { echo "linux block tests disabled"; exit 0; }

skip_or_fail() {
    if [[ "$mode" == required ]]; then echo "$1" >&2; exit 1; fi
    echo "linux block tests skipped: $1"
    exit 0
}

[[ $# -ge 3 ]] || skip_or_fail "Linux target is required"
probe=$2
cli=$3
[[ $(uname -s) == Linux ]] || skip_or_fail "Linux is required"
for command in losetup truncate blockdev fusermount3 mountpoint timeout; do
    command -v "$command" >/dev/null || skip_or_fail "$command is unavailable"
done
[[ -r /dev/fuse && -w /dev/fuse ]] || skip_or_fail "/dev/fuse is unavailable"
sudo -n true 2>/dev/null || skip_or_fail "passwordless sudo is unavailable"

work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-block.XXXXXX")
loop=
mount_pid=

cleanup() {
    set +e
    if sudo -n mountpoint -q "$work/mount" 2>/dev/null; then
        sudo -n timeout --kill-after=2s 5s fusermount3 -uz "$work/mount"
    fi
    if [[ -n "$mount_pid" ]]; then
        sudo -n kill -TERM "$mount_pid" 2>/dev/null
        wait "$mount_pid" 2>/dev/null
    fi
    [[ -z "$loop" ]] || sudo -n losetup --detach "$loop"
    rm -rf "$work"
}
trap cleanup EXIT

truncate --size 32MiB "$work/backing"
loop=$(sudo -n losetup --find --show "$work/backing") || skip_or_fail "no loop device is available"
sudo -n "$cli" device inspect "$loop" | grep -q '^Preflight: eligible$'
if sudo -n "$cli" format "$loop" >/dev/null 2>&1; then
    echo "standalone Blob format accepted a block device" >&2
    exit 1
fi

plan=$(sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected \
    --name-profile portable-v1 --label loop-cli)
grep -q '^Data mode: blob$' <<<"$plan"
grep -q '^Plan: ready$' <<<"$plan"
token=$(grep '^Confirm token: ' <<<"$plan")
token=${token#Confirm token: }
if sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli \
    --name-profile portable-v1 --confirm invalid >/dev/null 2>&1; then
    echo "invalid confirmation token was accepted" >&2
    exit 1
fi
sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli \
    --name-profile portable-v1 --confirm "$token" | grep -q '^Created pool: '

inspect=$(sudo -n "$cli" pool inspect --device "$loop")
grep -q '^Data mode: blob$' <<<"$inspect"
grep -q '^Mountable: yes$' <<<"$inspect"
if sudo -n "$cli" pool mount "$work/mount" --device "$loop" --filesystem blob >/dev/null 2>&1; then
    echo "pool mount accepted a filesystem selector" >&2
    exit 1
fi

mkdir "$work/mount"
start_mount() {
    : >"$work/mount.log"
    sudo -n timeout --kill-after=2s 30s "$cli" pool mount "$work/mount" --device "$loop" "$@" \
        >"$work/mount.log" 2>&1 &
    mount_pid=$!
    for _ in $(seq 1 100); do
        sudo -n mountpoint -q "$work/mount" && return
        kill -0 "$mount_pid" 2>/dev/null || { cat "$work/mount.log" >&2; return 1; }
        sleep 0.05
    done
    cat "$work/mount.log" >&2
    return 1
}

stop_mount() {
    sudo -n timeout --kill-after=2s 5s "$cli" unmount "$work/mount" >/dev/null
    wait "$mount_pid"
    mount_pid=
}

printf 'Blob Pool data' >"$work/expected"
start_mount --metrics
sudo -n "$probe" expect-busy "$loop"
sudo -n cp "$work/expected" "$work/mount/payload"
sudo -n sync -f "$work/mount/payload"
stop_mount
grep -q '^fuse_metrics ' "$work/mount.log"
grep -q '^pool_transport_metrics ' "$work/mount.log"
if grep -Eq '^(pipeline_metrics|member_transport_metrics) ' "$work/mount.log"; then
    echo "Blob Pool mount printed legacy metrics" >&2
    exit 1
fi

start_mount --read-only
sudo -n cmp "$work/expected" "$work/mount/payload"
if sudo -n touch "$work/mount/rejected" 2>/dev/null; then
    echo "read-only Blob Pool mount accepted a write" >&2
    exit 1
fi
stop_mount
