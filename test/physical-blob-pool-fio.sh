#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 5 ]] || {
    echo "usage: physical-blob-pool-fio.sh CLI DEVICE SERIAL ORIGINAL_POOL_ID BACKUP" >&2
    exit 2
}

cli=$1
device=$2
expected_serial=$3
original_pool_id=$4
backup=$5
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
keep_backup=${ZETTIDE_RAW_KEEP_BACKUP:-1}
backup_original=${ZETTIDE_BLOB_POOL_FIO_BACKUP_ORIGINAL:-1}
confirmation=${ZETTIDE_BLOB_POOL_FIO_CONFIRM:-}

[[ $EUID -eq 0 ]] || {
    echo "physical Blob Pool fio requires root" >&2
    exit 2
}
[[ $backup_original == 0 || $backup_original == 1 ]] || {
    echo "ZETTIDE_BLOB_POOL_FIO_BACKUP_ORIGINAL must be 0 or 1" >&2
    exit 2
}
[[ $backup_original == 0 || $original_pool_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "original Pool ID must be 32 lowercase hexadecimal digits" >&2
    exit 2
}
[[ $keep_backup == 0 || $keep_backup == 1 ]] || {
    echo "ZETTIDE_RAW_KEEP_BACKUP must be 0 or 1" >&2
    exit 2
}
[[ $confirmation == "DESTROY:$device:$expected_serial" ]] || {
    echo "destructive confirmation mismatch" >&2
    exit 2
}
for command in blkdiscard blockdev cmp dd df findmnt fuser grep lsblk stat udevadm wipefs; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done

mkdir -p "$log_dir"
backup_ready=false
device_modified=false
device_read_only=false
restore_verified=false
original_verified=false
test_succeeded=false
capacity=0
blob_pool_id=""

check_identity() {
    local actual_type actual_serial
    actual_type=$(lsblk --nodeps --noheadings --output TYPE "$device" | tr -d '[:space:]')
    actual_serial=$(lsblk --nodeps --noheadings --output SERIAL "$device" | tr -d '[:space:]')
    [[ $actual_type == disk && $actual_serial == "$expected_serial" ]] || {
        echo "physical Pool identity changed: $device ($actual_type, $actual_serial)" >&2
        return 1
    }
}

require_idle_device() {
    local descendant holder_dir kernel_name
    local -a descendants
    if lsblk --noheadings --raw --output MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
        echo "raw device has mounted descendants: $device" >&2
        return 1
    fi
    : >"$log_dir/device-holders.log"
    mapfile -t descendants < <(lsblk --noheadings --paths --raw --output NAME "$device")
    ((${#descendants[@]} > 0)) || return 1
    for descendant in "${descendants[@]}"; do
        if fuser "$descendant" >>"$log_dir/device-holders.log" 2>&1; then
            echo "raw device descendant is held by another process: $descendant" >&2
            return 1
        fi
        kernel_name=$(lsblk --nodeps --noheadings --output KNAME "$descendant" | tr -d '[:space:]')
        holder_dir="/sys/class/block/$kernel_name/holders"
        if [[ ! -d $holder_dir ]] || compgen -G "$holder_dir/*" >/dev/null; then
            echo "raw device descendant has kernel holders: $descendant" >&2
            return 1
        fi
    done
}

set_device_read_only() {
    blockdev --setro "$device"
    [[ $(blockdev --getro "$device") == 1 ]] || return 1
    device_read_only=true
}

set_device_writable() {
    blockdev --setrw "$device"
    [[ $(blockdev --getro "$device") == 0 ]] || return 1
    device_read_only=false
}

inspect_original() {
    "$cli" pool inspect --device "$device" >"$log_dir/pool-inspect-restored.log"
    grep -q "^Pool: $original_pool_id$" "$log_dir/pool-inspect-restored.log"
    grep -q '^Data mode: catalog$' "$log_dir/pool-inspect-restored.log"
    grep -q '^Mountable: yes$' "$log_dir/pool-inspect-restored.log"
}

finish() {
    local result=$?
    local cleanup_result=0
    trap - EXIT INT TERM
    set +e

    if [[ $backup_original == 1 && $device_modified == true && $backup_ready == true ]]; then
        if check_identity && require_idle_device && set_device_writable &&
            dd if="$backup" of="$device" bs=16M iflag=fullblock conv=fsync status=none &&
            blockdev --rereadpt "$device" &&
            udevadm settle &&
            cmp --bytes="$capacity" "$device" "$backup" &&
            inspect_original; then
            restore_verified=true
            original_verified=true
        else
            cleanup_result=1
        fi
    elif [[ $device_read_only == true ]]; then
        if ! check_identity || ! set_device_writable; then
            cleanup_result=1
        fi
    fi
    if [[ $cleanup_result -eq 0 && $test_succeeded == true && $restore_verified == true && $keep_backup == 0 ]]; then
        rm -f "$backup" || cleanup_result=1
    fi
    {
        echo "device=$device"
        echo "serial=$expected_serial"
        echo "backup_original=$backup_original"
        echo "original_pool_id=$original_pool_id"
        echo "blob_pool_id=$blob_pool_id"
        echo "backup=$backup"
        echo "backup_ready=$backup_ready"
        echo "device_modified=$device_modified"
        echo "device_read_only=$device_read_only"
        echo "test_succeeded=$test_succeeded"
        echo "restore_verified=$restore_verified"
        echo "original_verified=$original_verified"
    } >"$log_dir/lifecycle.log"

    if [[ $cleanup_result -ne 0 ]]; then
        echo "physical Blob Pool restoration failed; backup retained at $backup" >&2
        exit 1
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT TERM

[[ -x $cli ]] || {
    echo "Zettide CLI is not executable: $cli" >&2
    exit 2
}
check_identity
require_idle_device
if [[ $backup_original == 1 ]]; then
    [[ ! -e $backup ]] || {
        echo "refusing to overwrite backup: $backup" >&2
        exit 2
    }

    backup_dir=$(dirname "$backup")
    [[ -d $backup_dir && -w $backup_dir ]] || {
        echo "backup directory is not writable: $backup_dir" >&2
        exit 2
    }
    capacity=$(blockdev --getsize64 "$device")
    available=$(df --output=avail -B1 "$backup_dir" | tail -n 1 | tr -d '[:space:]')
    ((available > capacity)) || {
        echo "backup filesystem requires more than $capacity bytes free" >&2
        exit 2
    }
    backup_source=$(findmnt --noheadings --output SOURCE --target "$backup_dir")
    while read -r descendant; do
        [[ $backup_source != "$descendant" ]] || {
            echo "backup directory must not reside on the raw device" >&2
            exit 2
        }
    done < <(lsblk --noheadings --paths --raw --output NAME "$device")

    "$cli" pool inspect --device "$device" >"$log_dir/original-pool-inspect-before.log"
    grep -q "^Pool: $original_pool_id$" "$log_dir/original-pool-inspect-before.log"
    grep -q '^Data mode: catalog$' "$log_dir/original-pool-inspect-before.log"
    grep -q '^Mountable: yes$' "$log_dir/original-pool-inspect-before.log"

    set_device_read_only
    dd if="$device" of="$backup" bs=16M iflag=fullblock conv=sparse,fsync status=none
    [[ $(stat --format=%s "$backup") -eq $capacity ]] || {
        echo "raw-device backup image has the wrong size" >&2
        exit 1
    }
    cmp --bytes="$capacity" "$device" "$backup"
    backup_ready=true
fi

check_identity
require_idle_device
if [[ $backup_original == 1 ]]; then
    [[ $(blockdev --getro "$device") == 1 ]]
fi
set_device_writable
check_identity
require_idle_device
device_modified=true
wipefs --all --lock=yes "$device"
blockdev --rereadpt "$device"
udevadm settle
check_identity
blkdiscard --zeroout "$device"
blockdev --rereadpt "$device"
udevadm settle

check_identity
require_idle_device
"$cli" pool plan-create --device "$device" --profile unprotected \
    --name-profile portable-v1 --label physical-blob-fio >"$log_dir/blob-plan.log"
grep -q '^Data mode: blob$' "$log_dir/blob-plan.log"
grep -q '^Plan: ready$' "$log_dir/blob-plan.log"
token=$(grep '^Confirm token: ' "$log_dir/blob-plan.log")
token=${token#Confirm token: }
[[ $token =~ ^[0-9a-f]{64}$ ]] || {
    echo "Blob Pool plan did not return a confirmation token" >&2
    exit 1
}
check_identity
"$cli" pool create --device "$device" --profile unprotected \
    --name-profile portable-v1 --label physical-blob-fio --confirm "$token" >"$log_dir/blob-create.log"
blob_pool_id=$(grep '^Created pool: ' "$log_dir/blob-create.log")
blob_pool_id=${blob_pool_id#Created pool: }
[[ $blob_pool_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "Blob Pool creation did not return a Pool ID" >&2
    exit 1
}

"$cli" pool inspect --device "$device" >"$log_dir/blob-inspect.log"
grep -q "^Pool: $blob_pool_id$" "$log_dir/blob-inspect.log"
grep -q '^Data mode: blob$' "$log_dir/blob-inspect.log"
grep -q '^Mountable: yes$' "$log_dir/blob-inspect.log"

bash test/physical-pool-fio.sh "$cli" "$device" "$expected_serial" "$blob_pool_id"
test_succeeded=true
if [[ $backup_original == 1 ]]; then
    echo "physical Blob Pool fio passed; restoring $original_pool_id"
else
    echo "physical Blob Pool fio passed; retained $blob_pool_id"
fi
