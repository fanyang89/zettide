#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
probe=${3:-}
durability_probe=${4:-}

skip_or_fail() {
    if [[ "$mode" == required ]]; then
        echo "FUSE tests required: $1" >&2
        exit 1
    fi
    echo "FUSE tests skipped: $1"
    exit 0
}

[[ "$mode" != off ]] || { echo "FUSE tests disabled"; exit 0; }
[[ $(uname -s) == Linux ]] || skip_or_fail "Linux is required"
[[ -r /dev/fuse && -w /dev/fuse ]] || skip_or_fail "/dev/fuse is unavailable"
command -v fusermount3 >/dev/null || skip_or_fail "fusermount3 is unavailable"
command -v mountpoint >/dev/null || skip_or_fail "mountpoint is unavailable"
[[ -x "$probe" ]] || skip_or_fail "syscall probe was not built"
[[ -x "$durability_probe" ]] || skip_or_fail "durability probe was not built"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/devdrive-fuse.XXXXXX")
image="$tmp/image.ddv"
mount_dir="$tmp/mount"
log="$tmp/mount.log"
mount_pid=
durability_pid=

cleanup() {
    status=$?
    set +e
    if [[ $status -ne 0 && -s "$log" ]]; then cat "$log" >&2; fi
    if mountpoint -q "$mount_dir"; then fusermount3 -uz "$mount_dir"; fi
    if [[ -n "$mount_pid" ]]; then
        kill -TERM "$mount_pid" 2>/dev/null
        wait "$mount_pid" 2>/dev/null
    fi
    if [[ -n "$durability_pid" ]]; then
        kill -TERM "$durability_pid" 2>/dev/null
        wait "$durability_pid" 2>/dev/null
    fi
    rm -rf "$tmp"
    return "$status"
}
trap cleanup EXIT INT TERM

start_mount() {
    : >"$log"
    "$exe" mount "$image" "$mount_dir" >"$log" 2>&1 &
    mount_pid=$!
    for _ in $(seq 1 100); do
        mountpoint -q "$mount_dir" && return 0
        kill -0 "$mount_pid" 2>/dev/null || { cat "$log" >&2; return 1; }
        sleep 0.05
    done
    cat "$log" >&2
    echo "mount readiness timeout" >&2
    return 1
}

stop_mount() {
    "$exe" unmount "$mount_dir" >/dev/null
    for _ in $(seq 1 100); do
        if ! mountpoint -q "$mount_dir"; then
            wait "$mount_pid"
            mount_pid=
            return 0
        fi
        sleep 0.05
    done
    echo "unmount timeout" >&2
    return 1
}

mkdir "$mount_dir"
"$exe" create "$image" --size 8MiB --label "FUSE Test"
start_mount

root_mtime_before=$(stat -c %Y "$mount_dir")
sleep 1
printf 'hello from fuse' >"$mount_dir/hello.txt"
[[ $(<"$mount_dir/hello.txt") == "hello from fuse" ]]
mkdir "$mount_dir/subdir"
ln -s ../hello.txt "$mount_dir/subdir/link"
[[ $(readlink "$mount_dir/subdir/link") == ../hello.txt ]]
[[ $(<"$mount_dir/subdir/link") == "hello from fuse" ]]
chmod 750 "$mount_dir/hello.txt"
touch -d @1577905445 "$mount_dir/hello.txt"
[[ $(stat -c '%a %s %Y' "$mount_dir/hello.txt") == "750 15 1577905445" ]]

"$probe" "$mount_dir"

if unlink "$mount_dir/subdir" >/dev/null 2>&1; then
    echo "unlink(directory) unexpectedly succeeded" >&2
    exit 1
fi
if rmdir "$mount_dir/hello.txt" >/dev/null 2>&1; then
    echo "rmdir(file) unexpectedly succeeded" >&2
    exit 1
fi

stop_mount
"$exe" check "$image" >/dev/null
start_mount
[[ $(<"$mount_dir/hello.txt") == "hello from fuse" ]]
[[ $(stat -c '%a %s %Y' "$mount_dir/hello.txt") == "750 15 1577905445" ]]
root_mtime_after=$(stat -c %Y "$mount_dir")
(( root_mtime_after > root_mtime_before )) || { echo "parent directory mtime did not advance" >&2; exit 1; }
stop_mount

# Successful msync and fsync calls must survive abrupt daemon termination while
# the mapping and file descriptor remain open.
start_mount
ready="$tmp/durability.ready"
"$durability_probe" prepare "$mount_dir/crash.txt" "$ready" &
durability_pid=$!
for _ in $(seq 1 200); do
    [[ -e "$ready" ]] && break
    kill -0 "$durability_pid" 2>/dev/null || { echo "durability probe exited early" >&2; exit 1; }
    sleep 0.05
done
[[ -e "$ready" ]] || { echo "durability probe readiness timeout" >&2; exit 1; }
kill -KILL "$mount_pid"
wait "$mount_pid" 2>/dev/null || true
mount_pid=
kill -TERM "$durability_pid" 2>/dev/null || true
wait "$durability_pid" 2>/dev/null || true
durability_pid=
fusermount3 -uz "$mount_dir" 2>/dev/null || true
for _ in $(seq 1 100); do
    if ! mountpoint -q "$mount_dir" && stat "$mount_dir" >/dev/null 2>&1; then break; fi
    sleep 0.05
done
if mountpoint -q "$mount_dir" || ! stat "$mount_dir" >/dev/null 2>&1; then
    echo "dead FUSE process left a disconnected mount" >&2
    exit 1
fi
"$exe" check "$image" >/dev/null
start_mount
"$durability_probe" verify "$mount_dir/crash.txt"
stop_mount

# Repeated lifecycle checks catch leaked locks, mountpoints, and processes.
for _ in $(seq 1 16); do
    start_mount
    "$durability_probe" verify "$mount_dir/crash.txt"
    stop_mount
done
if mountpoint -q "$mount_dir"; then
    echo "mount remained active after unmount" >&2
    exit 1
fi
