#!/usr/bin/env bash

external_skip_or_fail() {
    local reason=$1
    if [[ "$external_mode" == required ]]; then
        echo "$external_suite tests required: $reason" >&2
        exit 1
    fi
    echo "$external_suite tests skipped: $reason"
    exit 0
}

external_initialize() {
    external_suite=$1
    external_mode=$2
    external_exe=$3
    external_image_size=${4:-256MiB}

    [[ "$external_mode" != off ]] || { echo "$external_suite tests disabled"; exit 0; }
    [[ $(uname -s) == Linux ]] || external_skip_or_fail "Linux is required"
    [[ -r /dev/fuse && -w /dev/fuse ]] || external_skip_or_fail "/dev/fuse is unavailable"
    command -v fusermount3 >/dev/null || external_skip_or_fail "fusermount3 is unavailable"
    command -v mountpoint >/dev/null || external_skip_or_fail "mountpoint is unavailable"
    command -v timeout >/dev/null || external_skip_or_fail "timeout is unavailable"
    [[ -x "$external_exe" ]] || external_skip_or_fail "devdrive executable was not built"

    external_tmp=$(mktemp -d "${TMPDIR:-/tmp}/devdrive-$external_suite.XXXXXX")
    external_image="$external_tmp/image.ddv"
    external_mount_dir="$external_tmp/mount"
    external_mount_log="$external_tmp/mount.log"
    external_mount_pid=
    mkdir "$external_mount_dir"
    "$external_exe" create "$external_image" --size "$external_image_size" --label "External Test" >/dev/null
    trap external_cleanup EXIT INT TERM
}

external_cleanup() {
    local status=$?
    set +e
    if [[ $status -ne 0 && -s "$external_mount_log" ]]; then
        printf '%s\n' "--- devdrive mount log ---" >&2
        command cat "$external_mount_log" >&2
    fi
    if mountpoint -q "$external_mount_dir"; then
        fusermount3 -uz "$external_mount_dir"
    fi
    if [[ -n "$external_mount_pid" ]]; then
        kill -TERM "$external_mount_pid" 2>/dev/null
        wait "$external_mount_pid" 2>/dev/null
    fi
    if [[ $status -ne 0 && ${DEVDRIVE_KEEP_TEST_ARTIFACTS:-0} == 1 ]]; then
        echo "$external_suite test artifacts retained at $external_tmp" >&2
    else
        rm -rf "$external_tmp"
    fi
    return "$status"
}

external_start_mount() {
    : >"$external_mount_log"
    "$external_exe" mount "$external_image" "$external_mount_dir" >"$external_mount_log" 2>&1 &
    external_mount_pid=$!
    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        mountpoint -q "$external_mount_dir" && return 0
        if ! kill -0 "$external_mount_pid" 2>/dev/null; then
            command cat "$external_mount_log" >&2
            return 1
        fi
        sleep 0.05
    done
    command cat "$external_mount_log" >&2
    echo "mount readiness timeout" >&2
    return 1
}

external_stop_mount() {
    "$external_exe" unmount "$external_mount_dir" >/dev/null
    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        if ! mountpoint -q "$external_mount_dir"; then
            wait "$external_mount_pid"
            external_mount_pid=
            return 0
        fi
        sleep 0.05
    done
    echo "unmount timeout" >&2
    return 1
}
