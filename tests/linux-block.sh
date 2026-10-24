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
for command in losetup truncate blockdev mount umount mkfs.ext4; do
    command -v "$command" >/dev/null || skip_or_fail "$command is unavailable"
done
sudo -n true 2>/dev/null || skip_or_fail "passwordless sudo is unavailable"

tmp_root=${TMPDIR:-$HOME/tmp}/opencode
mkdir -p "$tmp_root"
work=$(mktemp -d "$tmp_root/zettide-block.XXXXXX")
loop=
replica_loops=()
mounted=false
cleanup() {
    set +e
    if $mounted; then sudo -n umount "$work/mount"; fi
    [[ -z "$loop" ]] || sudo -n losetup --detach "$loop"
    for replica_loop in "${replica_loops[@]}"; do sudo -n losetup --detach "$replica_loop"; done
    rm -rf "$work"
}
trap cleanup EXIT

truncate --size 32MiB "$work/backing"
loop=$(sudo -n losetup --find --show "$work/backing") || skip_or_fail "no loop device is available"
sudo -n "$cli" device inspect "$loop" | grep -q '^Preflight: eligible$'
sudo -n blockdev --setro "$loop"
sudo -n "$probe" expect-read-only "$loop"
sudo -n blockdev --setrw "$loop"
sudo -n "$probe" check-exclusive "$loop"

plan=$(sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected --label loop-cli)
grep -q '^Data mode: catalog$' <<<"$plan"
grep -q '^Plan: ready$' <<<"$plan"
token=$(grep '^Confirm token: ' <<<"$plan")
token=${token#Confirm token: }
for label in loop-cli changed-label; do
    confirmation=invalid
    [[ "$label" == loop-cli ]] || confirmation=$token
    if sudo -n "$cli" pool create --device "$loop" --profile unprotected --label "$label" \
        --confirm "$confirmation" >/dev/null 2>&1; then
        echo "invalid or mismatched confirmation token was accepted" >&2
        exit 1
    fi
done
sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli \
    --confirm "$token" | grep -q '^Created pool: '
inspect=$(sudo -n "$cli" pool inspect --device "$loop")
grep -q '^Data mode: catalog$' <<<"$inspect"
grep -q '^Catalog: uninitialized$' <<<"$inspect"
sudo -n "$probe" reopen "$loop"

# Existing Pool data must never be overwritten by a new plan or an old token.
replan=$(sudo -n "$cli" pool plan-create --device "$loop" --profile unprotected --label loop-cli)
grep -q '^Plan: rejected$' <<<"$replan"
if sudo -n "$cli" pool create --device "$loop" --profile unprotected --label loop-cli \
    --confirm "$token" >/dev/null 2>&1; then
    echo "existing Pool accepted a stale creation token" >&2
    exit 1
fi

# The retained protected profile provisions three local Members, not one disk
# silently downgraded to unprotected mode.
replica_args=()
for index in 0 1 2; do
    truncate --size 32MiB "$work/replica-$index"
    replica_loop=$(sudo -n losetup --find --show "$work/replica-$index")
    replica_loops+=("$replica_loop")
    replica_args+=(--device "$replica_loop")
done
plan=$(sudo -n "$cli" pool plan-create "${replica_args[@]}" --profile replicated --label replicated-cli)
grep -q '^Profile: replicated$' <<<"$plan"
grep -q '^Data mode: catalog$' <<<"$plan"
token=$(grep '^Confirm token: ' <<<"$plan")
token=${token#Confirm token: }
sudo -n "$cli" pool create "${replica_args[@]}" --profile replicated --label replicated-cli \
    --confirm "$token" | grep -q '^Created pool: '
inspect=$(sudo -n "$cli" pool inspect "${replica_args[@]}")
grep -q '^Members: 3/3$' <<<"$inspect"
grep -q '^Profile: replicated$' <<<"$inspect"
grep -q '^Data mode: catalog$' <<<"$inspect"
sudo -n "$probe" reopen "${replica_loops[@]}"

sudo -n losetup --detach "$loop"
loop=
truncate --size 32MiB "$work/mounted-backing"
loop=$(sudo -n losetup --find --show "$work/mounted-backing")
sudo -n mkfs.ext4 -q "$loop"
mkdir "$work/mount"
sudo -n mount "$loop" "$work/mount"
mounted=true
sudo -n "$probe" expect-mounted "$loop"
