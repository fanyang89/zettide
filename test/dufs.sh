#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
signal_mask_exec=${3:-}

skip_or_fail() {
    if [[ "$mode" == required ]]; then
        echo "dufs tests required: $1" >&2
        exit 1
    fi
    echo "dufs tests skipped: $1"
    exit 0
}

[[ "$mode" != off ]] || { echo "dufs tests disabled"; exit 0; }
[[ $(uname -s) == Linux ]] || skip_or_fail "Linux is required"
[[ -r /dev/fuse && -w /dev/fuse ]] || skip_or_fail "/dev/fuse is unavailable"
command -v dufs >/dev/null || skip_or_fail "dufs is unavailable"
command -v curl >/dev/null || skip_or_fail "curl is unavailable"
command -v timeout >/dev/null || skip_or_fail "timeout is unavailable"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-dufs.XXXXXX")
image="$tmp/image.ddv"
log="$tmp/serve.log"
payload="$tmp/payload"
serve_pid=
serve_mount=

cleanup() {
    status=$?
    set +e
    if [[ -n "$serve_pid" ]]; then
        kill -TERM "$serve_pid" 2>/dev/null
        wait "$serve_pid" 2>/dev/null
    fi
    if [[ $status -ne 0 && -s "$log" ]]; then cat "$log" >&2; fi
    rm -rf "$tmp"
    return "$status"
}
trap cleanup EXIT INT TERM

start_server() {
    local port=$1
    local access=$2
    local launcher=()
    if [[ "$access" == masked ]]; then
        [[ -x "$signal_mask_exec" ]] || skip_or_fail "signal mask helper was not built"
        launcher=("$signal_mask_exec")
        access=writable
    fi
    : >"$log"
    if [[ "$access" == writable ]]; then
        "${launcher[@]}" "$exe" serve dufs "$image" -- -A -b 127.0.0.1 -p "$port" >"$log" 2>&1 &
    else
        "${launcher[@]}" "$exe" serve dufs "$image" --read-only -- -b 127.0.0.1 -p "$port" >"$log" 2>&1 &
    fi
    serve_pid=$!
    for _ in $(seq 1 100); do
        if curl --fail --silent --max-time 1 "http://127.0.0.1:$port/__dufs__/health" >/dev/null 2>&1; then
            serve_mount=$(awk '$5 ~ /zettide-dufs-/ { print $5; exit }' "/proc/$serve_pid/mountinfo")
            [[ -n "$serve_mount" ]] || { echo "private FUSE mount not found" >&2; return 1; }
            return 0
        fi
        kill -0 "$serve_pid" 2>/dev/null || { cat "$log" >&2; return 1; }
        sleep 0.05
    done
    echo "dufs readiness timeout" >&2
    return 1
}

stop_server() {
    kill -TERM "$serve_pid"
    wait "$serve_pid"
    serve_pid=
    if grep -Fq " $serve_mount " /proc/self/mountinfo; then
        echo "dufs serve left its private mount active" >&2
        exit 1
    fi
    if [[ -e "$serve_mount" ]]; then
        echo "dufs serve left its private directory" >&2
        exit 1
    fi
    serve_mount=
}

"$exe" format "$image" --size 8MiB >/dev/null
set +e
timeout 5s "$exe" serve dufs "$image" -- --hidden >/dev/null 2>&1
missing_value_status=$?
set -e
if [[ $missing_value_status -eq 0 || $missing_value_status -eq 124 ]]; then
    echo "dufs option without a value unexpectedly succeeded" >&2
    exit 1
fi
"$exe" serve dufs "$image" -- --version >/dev/null
set +e
timeout 5s env PATH=/nonexistent "$exe" serve dufs "$image" >/dev/null 2>&1
missing_dufs_status=$?
set -e
if [[ $missing_dufs_status -eq 0 || $missing_dufs_status -eq 124 ]]; then
    echo "serve unexpectedly found dufs outside PATH" >&2
    exit 1
fi

printf 'dufs payload' >"$payload"
port=$((20000 + $$ % 20000))
start_server "$port" writable
curl --fail --silent --show-error -T "$payload" "http://127.0.0.1:$port/payload" -o /dev/null
curl --fail --silent --show-error "http://127.0.0.1:$port/payload" -o "$tmp/download"
cmp "$payload" "$tmp/download"
stop_server

port=$((port + 1))
dd if=/dev/zero of="$tmp/large" bs=1M count=4 status=none
start_server "$port" writable
curl --silent --limit-rate 64k -T "$tmp/large" "http://127.0.0.1:$port/partial" -o /dev/null &
upload_pid=$!
sleep 0.1
stop_server
wait "$upload_pid" 2>/dev/null || true

port=$((port + 1))
start_server "$port" masked
stop_server

port=$((port + 1))
start_server "$port" read-only
curl --fail --silent --show-error "http://127.0.0.1:$port/payload" -o "$tmp/persisted"
cmp "$payload" "$tmp/persisted"
if curl --fail --silent --show-error -T "$payload" "http://127.0.0.1:$port/rejected" -o /dev/null 2>/dev/null; then
    echo "read-only dufs server accepted an upload" >&2
    exit 1
fi
stop_server

"$exe" check "$image" >/dev/null
