#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
target_kind=$3

skip_or_fail() {
    if [[ "$mode" == required ]]; then
        echo "SMB3 tests required: $1" >&2
        exit 1
    fi
    echo "SMB3 tests skipped: $1"
    exit 0
}

[[ "$mode" != off ]] || { echo "SMB3 tests disabled"; exit 0; }
[[ "$target_kind" == native ]] || skip_or_fail "native Linux target is required"
[[ $(uname -s) == Linux ]] || skip_or_fail "Linux is required"
[[ -r /dev/fuse && -w /dev/fuse ]] || skip_or_fail "/dev/fuse is unavailable"
for command in fusermount3 mountpoint ps python3 setsid smbd smbclient testparm; do
    command -v "$command" >/dev/null || skip_or_fail "$command is unavailable"
done
timeout_command=
for candidate in "$(command -v timeout 2>/dev/null || true)" /usr/bin/timeout; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" --kill-after=1s 0.01s true >/dev/null 2>&1; then
        timeout_command=$candidate
        break
    fi
done
[[ -n "$timeout_command" ]] || skip_or_fail "GNU-compatible timeout is unavailable"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-smb3.XXXXXX")
image="$tmp/image.ddv"
mount_dir="$tmp/mount"
private_dir="$tmp/private"
state_dir="$tmp/state"
cache_dir="$tmp/cache"
lock_dir="$tmp/lock"
config="$tmp/smb.conf"
auth_file="$tmp/auth"
password_file="$tmp/smbpasswd"
mount_log="$tmp/mount.log"
smbd_log="$tmp/smbd.log"
smbd_console_log="$tmp/smbd-console.log"
smbclient_log="$tmp/smbclient.log"
testparm_log="$tmp/testparm.log"
payload="$tmp/payload"
download="$tmp/download"
mount_pid=
smbd_pid=
port=
user=$(id -un)
password=password
password_changed=$(printf '%08X' "$(date +%s)")

cleanup() {
    status=$?
    set +e
    if [[ -n "$smbd_pid" ]]; then
        stop_smbd >/dev/null 2>&1
    fi
    if mountpoint -q "$mount_dir"; then "$timeout_command" --kill-after=1s 5s "$exe" unmount "$mount_dir" >/dev/null 2>&1; fi
    if [[ -n "$mount_pid" ]]; then
        kill -TERM "$mount_pid" 2>/dev/null
        if ! wait_for_exit "$mount_pid"; then kill -KILL "$mount_pid" 2>/dev/null; fi
        wait "$mount_pid" 2>/dev/null
    fi
    if mountpoint -q "$mount_dir"; then fusermount3 -uz "$mount_dir"; fi
    if [[ $status -ne 0 ]]; then
        [[ ! -s "$mount_log" ]] || cat "$mount_log" >&2
        [[ ! -s "$smbd_log" ]] || cat "$smbd_log" >&2
        [[ ! -s "$smbd_console_log" ]] || cat "$smbd_console_log" >&2
        [[ ! -s "$smbclient_log" ]] || cat "$smbclient_log" >&2
        [[ ! -s "$testparm_log" ]] || cat "$testparm_log" >&2
    fi
    rm -rf "$tmp"
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_exit() {
    local pid=$1
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

wait_for_process_group() {
    local process_group=$1
    for _ in $(seq 1 100); do
        process_group_has_live_members "$process_group" || return 0
        sleep 0.05
    done
    return 1
}

process_group_has_live_members() {
    local expected_group=$1
    local process_group state
    while read -r process_group state; do
        if [[ "$process_group" == "$expected_group" && "$state" != Z* ]]; then
            return 0
        fi
    done < <(ps -eo pgid=,stat=)
    return 1
}

choose_port() {
    python3 - <<'PY'
import socket

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

write_config() {
    local read_only=$1
    cat >"$config" <<EOF
[global]
    server role = standalone server
    workgroup = WORKGROUP
    security = user
    map to guest = Never
    server min protocol = SMB3_00
    server max protocol = SMB3_11
    server signing = mandatory
    smb encrypt = required
    server multi channel support = no
    interfaces = 127.0.0.1
    bind interfaces only = yes
    smb ports = $port
    passdb backend = smbpasswd
    smb passwd file = $password_file
    private dir = $private_dir
    state directory = $state_dir
    cache directory = $cache_dir
    lock directory = $lock_dir
    pid directory = $state_dir
    ncalrpc dir = $state_dir
    log file = $smbd_log
    logging = file
    load printers = no
    disable spoolss = yes
    printcap name = /dev/null
    dns proxy = no

[zettide]
    path = $mount_dir
    read only = $read_only
    guest ok = no
    browseable = no
    follow symlinks = no
    wide links = no
    ea support = no
    store dos attributes = no
    nt acl support = no
    durable handles = no
    kernel oplocks = no
    oplocks = yes
    level2 oplocks = yes
    strict sync = yes
EOF
    if ! testparm -s "$config" >"$testparm_log" 2>&1; then
        cat "$testparm_log" >&2
        return 1
    fi
}

start_mount() {
    : >"$mount_log"
    "$exe" mount "$image" "$mount_dir" >"$mount_log" 2>&1 &
    mount_pid=$!
    for _ in $(seq 1 100); do
        mountpoint -q "$mount_dir" && return 0
        kill -0 "$mount_pid" 2>/dev/null || return 1
        sleep 0.05
    done
    echo "SMB3 backing mount readiness timeout" >&2
    return 1
}

stop_mount() {
    "$timeout_command" --kill-after=1s 5s "$exe" unmount "$mount_dir" >/dev/null
    if ! wait_for_exit "$mount_pid"; then
        kill -KILL "$mount_pid" 2>/dev/null || true
        wait "$mount_pid" 2>/dev/null || true
        mount_pid=
        echo "SMB3 backing mount shutdown timeout" >&2
        return 1
    fi
    local mount_status
    if wait "$mount_pid"; then
        mount_status=0
    else
        mount_status=$?
    fi
    mount_pid=
    if [[ $mount_status -ne 0 ]]; then
        echo "SMB3 backing mount exited with status $mount_status" >&2
        return 1
    fi
}

start_smbd() {
    local read_only=$1
    for attempt in $(seq 1 3); do
        port=$(choose_port)
        write_config "$read_only"
        : >"$smbd_log"
        setsid smbd --foreground --no-process-group --debug-stdout --configfile="$config" >"$smbd_console_log" 2>&1 &
        smbd_pid=$!
        for poll in $(seq 1 100); do
            if smbclient "//127.0.0.1/zettide" --port="$port" \
                --authentication-file="$auth_file" --client-protection=encrypt \
                --option="client min protocol=SMB3_00" \
                --option="client max protocol=SMB3_11" \
                --option="client signing=required" \
                --command=quit >"$smbclient_log" 2>&1; then
                return 0
            fi
            if ! kill -0 "$smbd_pid" 2>/dev/null; then
                wait "$smbd_pid" 2>/dev/null || true
                smbd_pid=
                break
            fi
            sleep 0.05
        done
        if [[ -n "$smbd_pid" ]]; then
            echo "SMB3 server readiness timeout" >&2
            return 1
        fi
    done
    echo "SMB3 server failed to start after three temporary-port attempts" >&2
    return 1
}

stop_smbd() {
    local pid=$smbd_pid
    smbd_pid=
    kill -TERM -- "-$pid" 2>/dev/null || true
    if ! wait_for_process_group "$pid"; then
        kill -KILL -- "-$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo "SMB3 server shutdown timeout" >&2
        return 1
    fi
    wait "$pid" || true
}

smbclient_command() {
    smbclient "//127.0.0.1/zettide" --port="$port" \
        --authentication-file="$auth_file" --client-protection=encrypt \
        --option="client min protocol=SMB3_00" \
        --option="client max protocol=SMB3_11" \
        --option="client signing=required" \
        --command="$1"
}

mkdir "$mount_dir" "$private_dir" "$state_dir" "$cache_dir" "$lock_dir"
chmod 700 "$private_dir" "$state_dir" "$cache_dir" "$lock_dir"
cat >"$auth_file" <<EOF
username = $user
password = $password
EOF
chmod 600 "$auth_file"

# NT hash for the test-only password "password". The account still maps to the
# current host user, and the temporary passdb is removed after the test.
printf '%s:%s:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:8846F7EAEE8FB117AD06BDD830B7586C:[U          ]:LCT-%s:\n' \
    "$user" "$(id -u)" "$password_changed" >"$password_file"
chmod 600 "$password_file"

"$exe" format "$image" --size 16MiB >/dev/null

printf 'zettide SMB3 payload' >"$payload"
start_mount
start_smbd no
smbclient_command "mkdir data; cd data; put $payload payload.bin; rename payload.bin renamed.bin; get renamed.bin $download"
cmp "$payload" "$download"
stop_smbd
stop_mount
"$exe" check "$image" >/dev/null

start_mount
start_smbd yes
smbclient_command "get data/renamed.bin $download"
cmp "$payload" "$download"
if smbclient_command "put $payload rejected.bin" >/dev/null 2>&1; then
    echo "read-only SMB3 share accepted an upload" >&2
    exit 1
fi
if [[ -e "$mount_dir/rejected.bin" ]]; then
    echo "read-only SMB3 share changed the backing filesystem" >&2
    exit 1
fi
stop_smbd
stop_mount
"$exe" check "$image" >/dev/null
