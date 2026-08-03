#!/usr/bin/env bash

ZETTIDE_EXTERNAL_ROOT=${ZETTIDE_EXTERNAL_ROOT:-${DEVDRIVE_EXTERNAL_ROOT:-}}
ZETTIDE_KEEP_TEST_ARTIFACTS=${ZETTIDE_KEEP_TEST_ARTIFACTS:-${DEVDRIVE_KEEP_TEST_ARTIFACTS:-0}}
ZETTIDE_TEST_LOG_DIR=${ZETTIDE_TEST_LOG_DIR:-${DEVDRIVE_TEST_LOG_DIR:-}}
ZETTIDE_ALLOW_OTHER=${ZETTIDE_ALLOW_OTHER:-${DEVDRIVE_ALLOW_OTHER:-0}}
ZETTIDE_MOUNT_METRICS=${ZETTIDE_MOUNT_METRICS:-0}
ZETTIDE_REDO_JOURNAL_SIZE=${ZETTIDE_REDO_JOURNAL_SIZE:-}

external_skip_or_fail() {
    local reason=$1
    if [[ "$external_mode" == required ]]; then
        echo "$external_suite tests required: $reason" >&2
        exit 1
    fi
    echo "$external_suite tests skipped: $reason"
    exit 0
}

external_require_root() {
    [[ $EUID -eq 0 ]] && return 0
    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        local environment=(env "PATH=$PATH")
        local name
        for name in ZETTIDE_EXTERNAL_ROOT ZETTIDE_KEEP_TEST_ARTIFACTS ZETTIDE_TEST_LOG_DIR ZETTIDE_MOUNT_METRICS ZETTIDE_REDO_JOURNAL_SIZE; do
            if [[ -v $name ]]; then
                environment+=("$name=${!name}")
            fi
        done
        exec sudo -n "${environment[@]}" bash "$(readlink -f "$0")" "$@"
    fi
    external_skip_or_fail "root or passwordless sudo is required"
}

external_verify_pin() {
    local source_root=$1
    local expected=$2
    [[ -d "$source_root/.git" ]] || external_skip_or_fail "$source_root is not a prepared git checkout"
    local actual
    actual=$(git -C "$source_root" rev-parse HEAD 2>/dev/null) || external_skip_or_fail "cannot read source pin at $source_root"
    [[ "$actual" == "$expected" ]] || external_skip_or_fail "source pin mismatch at $source_root: expected $expected, found $actual"
}

external_validate_manifest() {
    local manifest=$1
    [[ -r "$manifest" ]] || external_skip_or_fail "manifest is unavailable: $manifest"
    local classification case_name contract reason extra required=0
    while IFS=$'\t' read -r classification case_name contract reason extra; do
        [[ -n "$classification" && ${classification:0:1} != "#" ]] || continue
        [[ -z "$extra" && -n "$case_name" && -n "$contract" && -n "$reason" ]] || {
            echo "invalid manifest row in $manifest: $classification $case_name" >&2
            return 1
        }
        [[ "$classification" == required || "$classification" == not-applicable ]] || {
            echo "invalid classification '$classification' in $manifest" >&2
            return 1
        }
        [[ "$case_name" != *'*'* && "$case_name" != *'?'* && "$case_name" != *'['* && "$case_name" != *','* ]] || {
            echo "broad case selector '$case_name' is forbidden in $manifest" >&2
            return 1
        }
        [[ "$classification" != required ]] || ((required += 1))
    done <"$manifest"
    ((required > 0)) || { echo "manifest has no required cases: $manifest" >&2; return 1; }
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
    [[ -x "$external_exe" ]] || external_skip_or_fail "zettide executable was not built"

    external_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-$external_suite.XXXXXX")
    external_image="$external_tmp/image.ddv"
    external_mount_dir="$external_tmp/mount"
    external_mount_log="$external_tmp/mount.log"
    external_mount_pid=
    chmod 0711 "$external_tmp"
    mkdir "$external_mount_dir"
    local create_args=(create "$external_image" --size "$external_image_size" --label "External Test")
    [[ -z $ZETTIDE_REDO_JOURNAL_SIZE ]] || create_args+=(--redo-journal-size "$ZETTIDE_REDO_JOURNAL_SIZE")
    "$external_exe" "${create_args[@]}" >/dev/null
    if [[ -n $ZETTIDE_TEST_LOG_DIR ]]; then
        mkdir -p "$ZETTIDE_TEST_LOG_DIR"
        exec > >(tee "$ZETTIDE_TEST_LOG_DIR/$external_suite.log") 2>&1
    fi
    trap external_cleanup EXIT INT TERM
}

external_require_identity_switch() {
    local check="$external_tmp/identity-check"
    command -v runuser >/dev/null || external_skip_or_fail "runuser is unavailable"
    [[ $(id -u nobody 2>/dev/null) == 65534 ]] || external_skip_or_fail "uid 65534 is not the nobody account"
    : >"$check"
    if ! chown 65534:65534 "$check" || ! runuser -u nobody -- test -w "$check"; then
        external_skip_or_fail "root cannot switch to an unprivileged identity"
    fi
    rm -f "$check"
}

external_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ $status -ne 0 && -s "$external_mount_log" ]]; then
        printf '%s\n' "--- zettide mount log ---" >&2
        command cat "$external_mount_log" >&2
    fi
    external_force_unmount
    if [[ -n "$external_mount_pid" ]]; then
        kill -TERM "$external_mount_pid" 2>/dev/null
        local attempt
        for ((attempt = 0; attempt < 50; attempt++)); do
            kill -0 "$external_mount_pid" 2>/dev/null || break
            sleep 0.05
        done
        kill -KILL "$external_mount_pid" 2>/dev/null
        wait "$external_mount_pid" 2>/dev/null
    fi
    if [[ -n $ZETTIDE_TEST_LOG_DIR && -s "$external_mount_log" ]]; then
        cp "$external_mount_log" "$ZETTIDE_TEST_LOG_DIR/$external_suite-mount.log"
    fi
    if [[ $status -ne 0 && $ZETTIDE_KEEP_TEST_ARTIFACTS == 1 ]]; then
        echo "$external_suite test artifacts retained at $external_tmp" >&2
    else
        rm -rf "$external_tmp"
    fi
    return "$status"
}

external_force_unmount() {
    [[ -n ${external_mount_dir:-} && -d "$external_mount_dir" ]] || return 0
    mountpoint -q "$external_mount_dir" || return 0
    fusermount3 -u "$external_mount_dir" 2>/dev/null || true
    local attempt
    for ((attempt = 0; attempt < 40; attempt++)); do
        mountpoint -q "$external_mount_dir" || return 0
        sleep 0.05
    done
    fusermount3 -uz "$external_mount_dir" 2>/dev/null || umount -l "$external_mount_dir" 2>/dev/null || true
}

external_start_mount() {
    : >"$external_mount_log"
    local mount_args=(mount "$external_image" "$external_mount_dir")
    [[ $ZETTIDE_ALLOW_OTHER != 1 ]] || mount_args+=(--allow-other)
    [[ $ZETTIDE_MOUNT_METRICS != 1 ]] || mount_args+=(--metrics)
    "$external_exe" "${mount_args[@]}" >"$external_mount_log" 2>&1 &
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
    "$external_exe" unmount "$external_mount_dir" >/dev/null || external_force_unmount
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
    external_force_unmount
    return 1
}
