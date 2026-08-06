#!/usr/bin/env bash
set -euo pipefail

mode=$1
exe=$2
target_kind=$3
ganesha_build=$4

skip_or_fail() {
    if [[ "$mode" == required ]]; then
        echo "NFS-Ganesha tests required: $1" >&2
        exit 1
    fi
    echo "NFS-Ganesha tests skipped: $1"
    exit 0
}

[[ "$mode" != off ]] || { echo "NFS-Ganesha tests disabled"; exit 0; }
[[ "$target_kind" == native ]] || skip_or_fail "native Linux target is required"
[[ $(uname -s) == Linux ]] || skip_or_fail "Linux is required"
[[ "$ganesha_build" != - ]] || skip_or_fail "-Dganesha-build-dir is required"

ganesha="$ganesha_build/ganesha.nfsd"
module="$ganesha_build/FSAL/FSAL_ZETTIDE/libfsalzettide.so"
for command in cmake grep mount mount.nfs mountpoint pgrep python3 rpcbind rpcinfo stat sudo sync timeout truncate umount; do
    command -v "$command" >/dev/null || skip_or_fail "$command is unavailable"
done
[[ -x "$ganesha" ]] || skip_or_fail "$ganesha is unavailable"
sudo -n true >/dev/null 2>&1 || skip_or_fail "passwordless sudo is unavailable"

cmake --build "$ganesha_build" --target fsalzettide -j2
[[ -f "$module" ]] || skip_or_fail "$module was not built"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-nfs-ganesha.XXXXXX")
image="$tmp/blob.ddv"
mount_dir="$tmp/mount"
config="$tmp/ganesha.conf"
log="$tmp/ganesha.log"
pid_file="$tmp/ganesha.pid"
ganesha_launcher_pid=
ganesha_pid=
rpcbind_started=false
rpcbind_pid=

cleanup() {
    status=$?
    set +e
    if mountpoint -q "$mount_dir"; then sudo -n timeout --kill-after=2s 15s umount "$mount_dir"; fi
    stop_ganesha
    if [[ "$rpcbind_started" == true && -n "$rpcbind_pid" ]]; then
        sudo -n kill -TERM "$rpcbind_pid" 2>/dev/null
    fi
    if [[ $status -ne 0 && -s "$log" ]]; then cat "$log" >&2; fi
    rm -rf "$tmp"
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

choose_port() {
    python3 - <<'PY'
import socket

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

nfs_port=$(choose_port)
mnt_port=$(choose_port)
while [[ "$mnt_port" == "$nfs_port" ]]; do mnt_port=$(choose_port); done
rquota_port=$(choose_port)
while [[ "$rquota_port" == "$nfs_port" || "$rquota_port" == "$mnt_port" ]]; do rquota_port=$(choose_port); done

write_config() {
    local access_type=$1
    local writable=$2

    cat >"$config" <<EOF
NFS_Core_Param {
    NFS_Port = $nfs_port;
    MNT_Port = $mnt_port;
    Rquota_Port = $rquota_port;
    Bind_Addr = 127.0.0.1;
    Protocols = 3;
    Enable_UDP = false;
    Plugins_Dir = "$ganesha_build/FSAL/FSAL_ZETTIDE";
    Enable_NFSACL = false;
    Allow_Set_Io_Flusher_Fail = true;
}

NFSv4 {
    RecoveryRoot = "$tmp";
}

EXPORT {
    Export_Id = 77;
    Path = "/zettide";
    Pseudo = "/zettide";
    Access_Type = $access_type;
    Squash = No_Root_Squash;
    Protocols = 3;
    Transports = TCP;
    SecType = sys;

    FSAL {
        name = ZETTIDE;
        Target = "$image";
        Writable = $writable;
        Stable_Write_Batch_Us = 4000;
    }
}
EOF
}

start_ganesha() {
    rm -f "$pid_file"
    : >"$log"
    sudo -n "$ganesha" -F -f "$config" -L "$log" -p "$pid_file" -N EVENT &
    ganesha_launcher_pid=$!
    for _ in $(seq 1 200); do
        if [[ -s "$pid_file" ]]; then
            ganesha_pid=$(<"$pid_file")
            if sudo -n kill -0 "$ganesha_pid" 2>/dev/null &&
                rpcinfo -p 127.0.0.1 2>/dev/null |
                    grep -Eq "^[[:space:]]*100003[[:space:]]+3[[:space:]]+tcp[[:space:]]+$nfs_port([[:space:]]|$)"; then
                return 0
            fi
        fi
        kill -0 "$ganesha_launcher_pid" 2>/dev/null || break
        sleep 0.05
    done
    cat "$log" >&2
    echo "NFS-Ganesha readiness timeout" >&2
    return 1
}

stop_ganesha() {
    if [[ -n "$ganesha_pid" ]]; then
        sudo -n kill -TERM "$ganesha_pid" 2>/dev/null || true
        for _ in $(seq 1 200); do
            sudo -n kill -0 "$ganesha_pid" 2>/dev/null || break
            sleep 0.05
        done
        if sudo -n kill -0 "$ganesha_pid" 2>/dev/null; then
            sudo -n kill -KILL "$ganesha_pid" 2>/dev/null || true
        fi
        ganesha_pid=
    fi
    if [[ -n "$ganesha_launcher_pid" ]]; then
        wait "$ganesha_launcher_pid" 2>/dev/null || true
        ganesha_launcher_pid=
    fi
}

mount_export() {
    sudo -n timeout --kill-after=2s 15s mount -t nfs \
        -o "vers=3,nolock,proto=tcp,port=$nfs_port,mountport=$mnt_port" \
        127.0.0.1:/zettide "$mount_dir"
}

if ! rpcinfo -p 127.0.0.1 >/dev/null 2>&1; then
    sudo -n rpcbind -w
    rpcbind_started=true
    for _ in $(seq 1 100); do
        if rpcinfo -p 127.0.0.1 >/dev/null 2>&1; then break; fi
        sleep 0.05
    done
    rpcinfo -p 127.0.0.1 >/dev/null 2>&1 || skip_or_fail "rpcbind failed to start"
    rpcbind_pid=$(pgrep -xo rpcbind)
fi

mkdir "$mount_dir"
"$exe" format "$image" --filesystem blob --size 64MiB >/dev/null
write_config RW true
start_ganesha
mount_export

root_inode=$(stat -c %i "$mount_dir")
printf 'hello from nfs' >"$mount_dir/payload.txt"
sync -f "$mount_dir/payload.txt"
mkdir "$mount_dir/directory"
ln "$mount_dir/payload.txt" "$mount_dir/payload-hardlink"
ln -s ../payload.txt "$mount_dir/directory/payload-symlink"
file_inode=$(stat -c %i "$mount_dir/payload.txt")
hardlink_inode=$(stat -c %i "$mount_dir/payload-hardlink")
[[ "$root_inode" != 0 && "$file_inode" != 0 && "$root_inode" != "$file_inode" ]]
[[ "$file_inode" == "$hardlink_inode" ]]
[[ $(<"$mount_dir/directory/payload-symlink") == "hello from nfs" ]]
chmod 640 "$mount_dir/payload.txt"
mv "$mount_dir/directory" "$mount_dir/renamed-directory"
truncate -s 5 "$mount_dir/payload.txt"
[[ $(<"$mount_dir/payload-hardlink") == hello ]]
sync -f "$mount_dir"

sudo -n timeout --kill-after=2s 15s umount "$mount_dir"
stop_ganesha
grep -q 'zettide_write_metrics stable_writes=' "$log"
start_ganesha
mount_export

[[ $(<"$mount_dir/payload.txt") == hello ]]
[[ $(<"$mount_dir/renamed-directory/payload-symlink") == hello ]]
[[ $(stat -c '%a:%s:%h' "$mount_dir/payload.txt") == 640:5:2 ]]
[[ $(stat -c %i "$mount_dir/payload.txt") == "$file_inode" ]]
[[ $(stat -c %i "$mount_dir/payload-hardlink") == "$file_inode" ]]
rm "$mount_dir/payload-hardlink"
printf ' again' >>"$mount_dir/payload.txt"
sync -f "$mount_dir/payload.txt"

sudo -n timeout --kill-after=2s 15s umount "$mount_dir"
stop_ganesha
"$exe" check "$image" >/dev/null

write_config RO false
start_ganesha
mount_export
[[ $(<"$mount_dir/payload.txt") == "hello again" ]]
if (printf x >"$mount_dir/rejected.txt") 2>/dev/null; then
    echo "read-only NFS export accepted a write" >&2
    exit 1
fi
sudo -n timeout --kill-after=2s 15s umount "$mount_dir"
stop_ganesha

echo "NFS-Ganesha NFSv3 RPC integration succeeded"
