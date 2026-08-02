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
command -v fusermount3 >/dev/null || skip_or_fail "fusermount3 is unavailable"
command -v mountpoint >/dev/null || skip_or_fail "mountpoint is unavailable"
command -v timeout >/dev/null || skip_or_fail "timeout is unavailable"
[[ -r /dev/fuse && -w /dev/fuse ]] || skip_or_fail "/dev/fuse is unavailable"
sudo -n true 2>/dev/null || skip_or_fail "passwordless sudo is unavailable"

work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-block.XXXXXX")
loop=""
format_loop=""
replica_loops=()
mounted=false
pool_mount_pid=""
cleanup() {
    if sudo -n mountpoint -q "$work/pool-mount" 2>/dev/null; then
        sudo -n timeout --kill-after=2s 5s fusermount3 -uz "$work/pool-mount" || true
    fi
    if [[ -n "$pool_mount_pid" ]]; then
        sudo -n kill -TERM "$pool_mount_pid" 2>/dev/null || true
        wait "$pool_mount_pid" 2>/dev/null || true
    fi
    if [[ "$mounted" == "true" ]]; then
        sudo -n umount "$work/mount" || true
    fi
    if [[ -n "$loop" ]]; then
        sudo -n losetup --detach "$loop" || true
    fi
    if [[ -n "$format_loop" ]]; then
        sudo -n losetup --detach "$format_loop" || true
    fi
    for replica_loop in "${replica_loops[@]}"; do
        sudo -n blockdev --setrw "$replica_loop" 2>/dev/null || true
        sudo -n losetup --detach "$replica_loop" || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

truncate --size 32MiB "$work/format-backing"
printf 'existing data' | dd of="$work/format-backing" conv=notrunc status=none
format_loop=$(sudo -n losetup --find --show "$work/format-backing") || skip_or_fail "no format loop device is available"
format_plan=$(sudo -n "$cli" format "$format_loop" --label format-cli)
grep -q '^Type: block_device$' <<<"$format_plan"
grep -q '^Contains data: yes$' <<<"$format_plan"
format_token=$(grep '^Confirm token: ' <<<"$format_plan")
format_token=${format_token#Confirm token: }
if sudo -n "$cli" format "$format_loop" --label format-cli --confirm invalid >/dev/null 2>&1; then
    echo "invalid format confirmation token was accepted" >&2
    exit 1
fi
sudo -n "$cli" format "$format_loop" --label format-cli --confirm "$format_token" \
    | grep -q '^Formatted '
sudo -n "$cli" info "$format_loop" | grep -q '^Label: format-cli$'
sudo -n "$cli" check "$format_loop" | grep -q '^Filesystem traversal succeeded:'

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
printf '\001' | sudo -n dd of="$loop" bs=1 seek=$((16 * 1024 * 1024)) conv=notrunc status=none
if sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli --confirm "$token" >/dev/null 2>&1; then
    echo "token was accepted after device contents changed" >&2
    exit 1
fi
printf '\000' | sudo -n dd of="$loop" bs=1 seek=$((16 * 1024 * 1024)) conv=notrunc status=none
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

for index in 0 1 2; do
    truncate --size 32MiB "$work/replica-$index"
    replica_loops+=("$(sudo -n losetup --find --show "$work/replica-$index")")
done
if sudo -n "$cli" pool plan-create \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --profile unprotected >/dev/null 2>&1; then
    echo "unsupported unprotected pool width was accepted" >&2
    exit 1
fi
replica_args=(
    --device "${replica_loops[0]}"
    --device "${replica_loops[1]}"
    --device "${replica_loops[2]}"
    --profile replicated
    --label replica-cli
)
replica_plan=$(sudo -n "$cli" pool plan-create "${replica_args[@]}")
replica_token=$(grep '^Confirm token: ' <<<"$replica_plan")
replica_token=${replica_token#Confirm token: }
sudo -n "$cli" pool create "${replica_args[@]}" --confirm "$replica_token" \
    | grep -q '^Created pool: '
inspect=$(sudo -n "$cli" pool inspect \
    --device "${replica_loops[2]}" \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}")
grep -q '^Profile: replicated$' <<<"$inspect"
grep -q '^Members: 3/3$' <<<"$inspect"
grep -q '^Data policy: read_write$' <<<"$inspect"
grep -q '^Mountable: yes$' <<<"$inspect"
degraded=$(sudo -n "$cli" pool inspect \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}")
grep -q '^Members: 2/3$' <<<"$degraded"
grep -q '^Data policy: read_only$' <<<"$degraded"
if sudo -n "$cli" pool inspect --device "${replica_loops[0]}" >/dev/null 2>&1; then
    echo "replicated pool opened without control quorum" >&2
    exit 1
fi

mkdir "$work/pool-mount"
printf 'physical pool data' >"$work/expected"
start_pool_mount() {
    mount_options=("$@")
    : >"$work/pool-mount.log"
    sudo -n timeout --kill-after=2s 30s "$cli" pool mount "$work/pool-mount" \
        --device "${replica_loops[0]}" \
        --device "${replica_loops[1]}" \
        --device "${replica_loops[2]}" "${mount_options[@]}" >"$work/pool-mount.log" 2>&1 &
    pool_mount_pid=$!
    for _ in $(seq 1 100); do
        sudo -n mountpoint -q "$work/pool-mount" && return 0
        kill -0 "$pool_mount_pid" 2>/dev/null || {
            cat "$work/pool-mount.log" >&2
            return 1
        }
        sleep 0.05
    done
    cat "$work/pool-mount.log" >&2
    echo "pool mount readiness timeout" >&2
    return 1
}
stop_pool_mount() {
    sudo -n timeout --kill-after=2s 5s "$cli" unmount "$work/pool-mount" >/dev/null
    for _ in $(seq 1 100); do
        if ! sudo -n mountpoint -q "$work/pool-mount"; then
            wait "$pool_mount_pid"
            pool_mount_pid=""
            return 0
        fi
        sleep 0.05
    done
    echo "pool unmount timeout" >&2
    return 1
}
start_pool_mount
sudo -n "$probe" expect-busy "${replica_loops[0]}"
sudo -n cp "$work/expected" "$work/pool-mount/hello.txt"
sudo -n sync -f "$work/pool-mount/hello.txt"
stop_pool_mount
start_pool_mount
sudo -n cmp "$work/expected" "$work/pool-mount/hello.txt"
stop_pool_mount
for replica_loop in "${replica_loops[@]}"; do
    sudo -n blockdev --setro "$replica_loop"
done
start_pool_mount --read-only
sudo -n cmp "$work/expected" "$work/pool-mount/hello.txt"
if sudo -n touch "$work/pool-mount/read-only-write" 2>/dev/null; then
    echo "read-only pool mount accepted a write" >&2
    exit 1
fi
stop_pool_mount
for replica_loop in "${replica_loops[@]}"; do
    sudo -n blockdev --setrw "$replica_loop"
done
initialized_pool=$(sudo -n "$cli" pool inspect \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}")
pool_id=$(grep '^Pool: ' <<<"$initialized_pool")
pool_id=${pool_id#Pool: }
if sudo -n "$cli" pool initialize \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}" \
    --confirm "initialize-empty-volume:$pool_id" >/dev/null 2>&1; then
    echo "initialized pool was reinitialized" >&2
    exit 1
fi
for replica_loop in "${replica_loops[@]}"; do
    sudo -n dd if=/dev/zero of="$replica_loop" bs=1M seek=1 count=31 conv=notrunc status=none
done
empty_pool=$(sudo -n "$cli" pool inspect \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}")
grep -q '^Mountable: no$' <<<"$empty_pool"
initialize_token=$(grep '^Initialize token: ' <<<"$empty_pool")
initialize_token=${initialize_token#Initialize token: }
if sudo -n "$cli" pool initialize \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}" \
    --confirm invalid >/dev/null 2>&1; then
    echo "invalid initialize token was accepted" >&2
    exit 1
fi
if sudo -n "$cli" pool initialize \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}" \
    --device "$loop" \
    --confirm "$initialize_token" >/dev/null 2>&1; then
    echo "pool initialize accepted an extra device" >&2
    exit 1
fi
sudo -n "$cli" pool initialize \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}" \
    --label recovered \
    --confirm "$initialize_token" | grep -q '^Initialized pool: '
sudo -n "$cli" pool inspect \
    --device "${replica_loops[0]}" \
    --device "${replica_loops[1]}" \
    --device "${replica_loops[2]}" | grep -q '^Mountable: yes$'
start_pool_mount
sudo -n cp "$work/expected" "$work/pool-mount/recovered.txt"
sudo -n cmp "$work/expected" "$work/pool-mount/recovered.txt"
stop_pool_mount
