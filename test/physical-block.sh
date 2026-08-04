#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 6 ]] || {
    echo "usage: physical-block.sh CLI DEVICE SERIAL MOUNTPOINT BACKUP TEST_MIB" >&2
    exit 2
}

cli=$1
device=$2
expected_serial=$3
original_mountpoint=$4
backup=$5
test_mib=$6
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
keep_backup=${ZETTIDE_RAW_KEEP_BACKUP:-1}
run_fio=${ZETTIDE_RAW_FIO:-0}
fio_size=${ZETTIDE_RAW_FIO_SIZE:-64G}
fio_runtime=${ZETTIDE_RAW_FIO_RUNTIME:-20}
fio_ramp_time=${ZETTIDE_RAW_FIO_RAMP_TIME:-5}
expected_confirm="DESTROY:${device}:${expected_serial}"

[[ ${ZETTIDE_RAW_DEVICE_CONFIRM:-} == "$expected_confirm" ]] || {
    echo "raw-device confirmation mismatch" >&2
    exit 2
}
[[ $EUID -eq 0 ]] || {
    echo "physical block testing requires root" >&2
    exit 2
}
[[ $test_mib =~ ^[1-9][0-9]*$ ]] || {
    echo "TEST_MIB must be a positive integer" >&2
    exit 2
}
[[ $keep_backup == 0 || $keep_backup == 1 ]] || {
    echo "ZETTIDE_RAW_KEEP_BACKUP must be 0 or 1" >&2
    exit 2
}
[[ $run_fio == 0 || $run_fio == 1 ]] || {
    echo "ZETTIDE_RAW_FIO must be 0 or 1" >&2
    exit 2
}
[[ $fio_runtime =~ ^[1-9][0-9]*$ && $fio_ramp_time =~ ^[0-9]+$ ]] || {
    echo "fio runtime and ramp time must be integer seconds" >&2
    exit 2
}

for command in blkdiscard blockdev blkid cmp dd findmnt flock fusermount3 grep lsblk mount mountpoint setsid sfdisk sha256sum stat timeout udevadm umount wipefs; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done
if [[ $run_fio == 1 ]]; then
    command -v fio >/dev/null || {
        echo "fio is required for raw-device performance testing" >&2
        exit 2
    }
fi

mkdir -p "$log_dir"
work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-physical-block.XXXXXX")
test_mountpoint="$work/mount"
mkdir "$test_mountpoint"

original_unmounted=false
backup_ready=false
device_modified=false
restore_verified=false
mount_verified=false
test_succeeded=false
mount_pid=""

check_identity() {
    local actual_type actual_serial
    actual_type=$(lsblk --nodeps --noheadings --output TYPE "$device" | tr -d '[:space:]')
    actual_serial=$(lsblk --nodeps --noheadings --output SERIAL "$device" | tr -d '[:space:]')
    [[ $actual_type == disk && $actual_serial == "$expected_serial" ]] || {
        echo "raw-device identity changed: $device ($actual_type, $actual_serial)" >&2
        return 1
    }
}

run_fio_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local jobs=$5
    fio \
        --name="$name" \
        --filename="$device" \
        --rw="$rw" \
        --bs="$block_size" \
        --size="$fio_size" \
        --ioengine=io_uring \
        --iodepth="$depth" \
        --numjobs="$jobs" \
        --direct=1 \
        --invalidate=1 \
        --group_reporting=1 \
        --time_based=1 \
        --runtime="$fio_runtime" \
        --ramp_time="$fio_ramp_time" \
        --randrepeat=0 \
        --norandommap=1 \
        --refill_buffers=1 \
        --percentile_list=50:95:99:99.9 \
        --eta=never \
        --output-format=json \
        --output="$log_dir/fio-$name.json"
}

stop_pool_mount() {
    if mountpoint -q "$test_mountpoint"; then
        timeout --kill-after=2s 10s "$cli" unmount "$test_mountpoint" >/dev/null 2>&1 ||
            timeout --kill-after=2s 10s fusermount3 -uz "$test_mountpoint" >/dev/null 2>&1 || true
    fi
    if [[ -n $mount_pid ]]; then
        for ((attempt = 0; attempt < 100; attempt++)); do
            kill -0 "$mount_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$mount_pid" 2>/dev/null; then
            kill -TERM -- "-$mount_pid" 2>/dev/null || true
            sleep 1
        fi
        if kill -0 "$mount_pid" 2>/dev/null; then
            kill -KILL -- "-$mount_pid" 2>/dev/null || true
        fi
        wait "$mount_pid" 2>/dev/null || true
        mount_pid=""
    fi
    ! mountpoint -q "$test_mountpoint"
}

start_pool_mount() {
    local log=$1
    shift
    : >"$log"
    setsid timeout --kill-after=5s 600s "$cli" pool mount "$test_mountpoint" \
        --device "$device" --allow-other "$@" >"$log" 2>&1 &
    mount_pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        if mountpoint -q "$test_mountpoint"; then
            return
        fi
        if ! kill -0 "$mount_pid" 2>/dev/null; then
            cat "$log" >&2
            return 1
        fi
        sleep 0.1
    done
    cat "$log" >&2
    echo "physical pool mount readiness timeout" >&2
    return 1
}

finish() {
    local result=$?
    local cleanup_result=0
    local pool_stopped=true
    local restored_source=""
    trap - EXIT INT TERM
    set +e

    if ! stop_pool_mount; then
        cleanup_result=1
        pool_stopped=false
    fi
    if [[ $device_modified == true && $backup_ready == true && $pool_stopped == true ]]; then
        if check_identity &&
            dd if="$backup" of="$device" bs=1M iflag=fullblock conv=fsync status=none &&
            blockdev --rereadpt "$device" &&
            udevadm settle &&
            cmp --bytes="$capacity" "$device" "$backup"; then
            restore_verified=true
        else
            cleanup_result=1
        fi
    fi
    if [[ $original_unmounted == true ]]; then
        if [[ $device_modified == false || $restore_verified == true ]]; then
            if mount "$original_mountpoint" && mountpoint -q "$original_mountpoint"; then
                restored_source=$(findmnt --noheadings --output SOURCE --target "$original_mountpoint")
                if [[ $restored_source == "$original_source" ]]; then
                    findmnt --noheadings --target "$original_mountpoint" >"$log_dir/restored-mount.log"
                    mount_verified=true
                else
                    cleanup_result=1
                fi
            else
                cleanup_result=1
            fi
        else
            cleanup_result=1
        fi
    fi
    if [[ $cleanup_result -eq 0 && $test_succeeded == true && $restore_verified == true && $mount_verified == true && $keep_backup == 0 ]]; then
        rm -f "$backup" || cleanup_result=1
    fi
    {
        echo "device=$device"
        echo "serial=$expected_serial"
        echo "backup=$backup"
        echo "backup_ready=$backup_ready"
        echo "fio_enabled=$run_fio"
        echo "test_succeeded=$test_succeeded"
        echo "restore_verified=$restore_verified"
        echo "mount_verified=$mount_verified"
    } >"$log_dir/lifecycle.log"
    rm -rf "$work"

    if [[ $cleanup_result -ne 0 ]]; then
        echo "raw-device restoration failed; backup retained at $backup" >&2
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

findmnt --fstab --noheadings --target "$original_mountpoint" >"$log_dir/fstab-mount.log"
original_source=$(findmnt --noheadings --output SOURCE --target "$original_mountpoint")
mapfile -t descendants < <(lsblk --noheadings --paths --raw --output NAME "$device")
source_is_descendant=false
for descendant in "${descendants[@]}"; do
    if [[ $original_source == "$descendant" ]]; then
        source_is_descendant=true
    fi
done
[[ $source_is_descendant == true ]] || {
    echo "$original_mountpoint is not mounted from $device" >&2
    exit 2
}

mapfile -t descendant_mounts < <(lsblk --noheadings --raw --output MOUNTPOINTS "$device" | while read -r path; do
    [[ -z $path ]] || printf '%s\n' "$path"
done)
[[ ${#descendant_mounts[@]} -eq 1 && ${descendant_mounts[0]} == "$original_mountpoint" ]] || {
    echo "raw disk must have only the configured descendant mount" >&2
    exit 2
}
backup_source=$(findmnt --noheadings --output SOURCE --target "$backup_dir")
for descendant in "${descendants[@]}"; do
    [[ $backup_source != "$descendant" ]] || {
        echo "backup directory must not reside on the raw device" >&2
        exit 2
    }
done

findmnt --noheadings --target "$original_mountpoint" >"$log_dir/original-mount.log"
lsblk --json --bytes --output NAME,PATH,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS,RO,PKNAME,MODEL,SERIAL "$device" \
    >"$log_dir/original-lsblk.json"
sfdisk --dump "$device" >"$log_dir/original-sfdisk.txt" 2>"$log_dir/original-sfdisk.stderr" || true
blkid "$device" "$original_source" >"$log_dir/original-blkid.txt" || true

umount "$original_mountpoint"
original_unmounted=true
dd if="$device" of="$backup" bs=1M iflag=fullblock conv=sparse,fsync status=none
[[ $(stat --format=%s "$backup") -eq $capacity ]] || {
    echo "raw-device backup image has the wrong size" >&2
    exit 1
}
cmp --bytes="$capacity" "$device" "$backup"
backup_ready=true

"$cli" device inspect "$device" >"$log_dir/unmounted-inspect.log"
grep -q '^Preflight: eligible$' "$log_dir/unmounted-inspect.log"

device_modified=true
check_identity
wipefs --all --lock=yes "$device"
blockdev --rereadpt "$device"
udevadm settle
check_identity
blkdiscard --zeroout "$device"
blockdev --rereadpt "$device"
udevadm settle
"$cli" device inspect "$device" >"$log_dir/empty-inspect.log"
grep -q '^Preflight: eligible$' "$log_dir/empty-inspect.log"

if [[ $run_fio == 1 ]]; then
    run_fio_case seq-write-1m-qd32-j1 write 1m 32 1
    run_fio_case seq-read-1m-qd32-j1 read 1m 32 1
    run_fio_case randwrite-4k-qd1-j1 randwrite 4k 1 1
    run_fio_case randread-4k-qd1-j1 randread 4k 1 1
    run_fio_case randwrite-4k-qd32-j1 randwrite 4k 32 1
    run_fio_case randread-4k-qd32-j1 randread 4k 32 1
    run_fio_case randwrite-4k-qd32-j4 randwrite 4k 32 4
    run_fio_case randread-4k-qd32-j4 randread 4k 32 4
    check_identity
    blkdiscard --zeroout "$device"
    blockdev --rereadpt "$device"
    udevadm settle
    "$cli" device inspect "$device" >"$log_dir/post-fio-inspect.log"
    grep -q '^Preflight: eligible$' "$log_dir/post-fio-inspect.log"
fi

"$cli" pool plan-create --device "$device" --profile unprotected --label physical-tier1 \
    >"$log_dir/plan.log"
grep -q '^Plan: ready$' "$log_dir/plan.log"
token=$(grep '^Confirm token: ' "$log_dir/plan.log")
token=${token#Confirm token: }
[[ $token =~ ^[0-9a-f]{64}$ ]] || {
    echo "physical pool plan did not return a confirmation token" >&2
    exit 1
}
"$cli" pool create --device "$device" --profile unprotected --label physical-tier1 --confirm "$token" \
    >"$log_dir/create.log"
"$cli" pool inspect --device "$device" >"$log_dir/inspect.log"
grep -q '^Profile: unprotected$' "$log_dir/inspect.log"
grep -q '^Members: 1/1$' "$log_dir/inspect.log"
grep -q '^Data policy: read_write$' "$log_dir/inspect.log"
grep -q '^Mountable: yes$' "$log_dir/inspect.log"

start_pool_mount "$log_dir/writable-mount.log"
dd if=/dev/urandom of="$test_mountpoint/persistence.bin" bs=1M count="$test_mib" conv=fsync status=none
payload_hash=$(sha256sum "$test_mountpoint/persistence.bin")
payload_hash=${payload_hash%% *}
if "$cli" pool create --device "$device" --profile unprotected --label busy-test --confirm invalid \
    >"$log_dir/busy-create.log" 2>&1; then
    echo "mounted raw pool accepted a second exclusive create" >&2
    exit 1
fi
grep -q 'DeviceBusy' "$log_dir/busy-create.log"
stop_pool_mount

"$cli" pool inspect --device "$device" >"$log_dir/reopen-inspect.log"
grep -q '^Mountable: yes$' "$log_dir/reopen-inspect.log"
start_pool_mount "$log_dir/read-only-mount.log" --read-only
reopened_hash=$(sha256sum "$test_mountpoint/persistence.bin")
reopened_hash=${reopened_hash%% *}
[[ $payload_hash == "$reopened_hash" ]] || {
    echo "physical raw pool payload changed after reopen" >&2
    exit 1
}
if touch "$test_mountpoint/read-only-write" 2>"$log_dir/read-only-write.log"; then
    echo "read-only physical raw pool accepted a write" >&2
    exit 1
fi
stop_pool_mount

echo "$payload_hash" >"$log_dir/payload.sha256"
test_succeeded=true
echo "physical raw-device test passed; restoring $device"
