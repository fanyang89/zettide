#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 5 ]] || {
    echo "usage: scheduled-blob-pool-fio.sh CLI DEVICE SERIAL ORIGINAL_POOL_ID BACKUP" >&2
    exit 2
}

cli=$1
device=$2
expected_serial=$3
original_pool_id=$4
backup=$5
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
keep_backup=${ZETTIDE_RAW_KEEP_BACKUP:-1}
confirmation=${ZETTIDE_SCHEDULED_BLOB_POOL_FIO_CONFIRM:-}

[[ $EUID -eq 0 ]] || {
    echo "scheduled Blob Pool fio requires root" >&2
    exit 2
}
[[ $keep_backup == 0 || $keep_backup == 1 ]] || {
    echo "ZETTIDE_RAW_KEEP_BACKUP must be 0 or 1" >&2
    exit 2
}
[[ $original_pool_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "original Pool ID must be 32 lowercase hexadecimal digits" >&2
    exit 2
}
[[ $confirmation == "DESTROY:$device:$expected_serial" ]] || {
    echo "scheduled destructive confirmation mismatch" >&2
    exit 2
}
for command in blkdiscard blockdev cmp date dd df dirname findmnt flock fuser grep jq losetup lsblk readlink rm stat tr udevadm wipefs; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done
[[ -x $cli ]] || {
    echo "Zettide CLI is not executable: $cli" >&2
    exit 2
}
[[ -b $device ]] || {
    echo "raw device is not a block device: $device" >&2
    exit 2
}

mkdir -p "$log_dir"
events_log="$log_dir/lifecycle-events.log"
: >"$events_log"

record_event() {
    printf '%s %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$events_log"
}

backup_ready=false
device_modified=false
device_read_only=false
restore_verified=false
original_verified=false
original_before_verified=false
original_mountable=""
test_succeeded=false
loops_detached=true
capacity=0
slice_size=0
scheduled_pool_id=""
loops=()
offsets=()

check_identity() {
    local actual_type actual_serial
    actual_type=$(lsblk --nodeps --noheadings --output TYPE "$device" | tr -d '[:space:]')
    actual_serial=$(lsblk --nodeps --json --output SERIAL "$device" |
        jq --exit-status --raw-output '.blockdevices | if length == 1 then .[0].serial else empty end')
    [[ $actual_type == disk && $actual_serial == "$expected_serial" ]] || {
        echo "physical device identity changed: $device ($actual_type, $actual_serial)" >&2
        return 1
    }
    record_event "identity-ok device=$device serial=$actual_serial type=$actual_type"
}

require_idle_device() {
    local descendant holder_dir kernel_name
    local -a descendants associated

    if lsblk --noheadings --raw --output MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
        echo "raw device has mounted descendants: $device" >&2
        return 1
    fi
    mapfile -t associated < <(losetup --associated "$device" --noheadings --raw --output NAME)
    if ((${#associated[@]} != 0)); then
        echo "raw device already backs loop devices: ${associated[*]}" >&2
        return 1
    fi
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
    record_event "idle-ok device=$device descendants=${#descendants[@]}"
}

set_device_read_only() {
    blockdev --setro "$device"
    [[ $(blockdev --getro "$device") == 1 ]] || return 1
    device_read_only=true
    record_event "device-read-only device=$device"
}

set_device_writable() {
    blockdev --setrw "$device"
    [[ $(blockdev --getro "$device") == 0 ]] || return 1
    device_read_only=false
    record_event "device-writable device=$device"
}

inspect_original() {
    local output=$1
    local actual_mountable
    "$cli" pool inspect --device "$device" >"$output" || return 1
    grep -q "^Pool: $original_pool_id$" "$output" || return 1
    grep -q '^Filesystem: littlefs$' "$output" || return 1
    actual_mountable=$(grep '^Mountable: ' "$output") || return 1
    actual_mountable=${actual_mountable#Mountable: }
    [[ $actual_mountable == yes || $actual_mountable == no ]] || return 1
    if [[ -z $original_mountable ]]; then
        original_mountable=$actual_mountable
    else
        [[ $actual_mountable == "$original_mountable" ]] || return 1
    fi
}

detach_loops() {
    local loop status=0
    local -a remaining

    for loop in "${loops[@]}"; do
        if losetup "$loop" >/dev/null 2>&1; then
            if losetup --detach "$loop"; then
                record_event "loop-detached loop=$loop"
            else
                echo "failed to detach loop device: $loop" >&2
                status=1
            fi
        fi
    done
    udevadm settle || status=1
    mapfile -t remaining < <(losetup --associated "$device" --noheadings --raw --output NAME)
    if ((${#remaining[@]} != 0)); then
        echo "loop devices remain attached to $device: ${remaining[*]}" >&2
        status=1
    fi
    if [[ $status -eq 0 ]]; then
        loops_detached=true
    else
        loops_detached=false
    fi
    return "$status"
}

finish() {
    local result=$?
    local cleanup_result=0
    trap - EXIT
    trap '' HUP INT TERM
    set +e

    record_event "cleanup-start command_rc=$result modified=$device_modified"
    detach_loops || cleanup_result=1
    if [[ $device_modified == true && $backup_ready == true ]]; then
        if [[ $loops_detached == true ]] &&
            check_identity && require_idle_device && set_device_writable &&
            dd if="$backup" of="$device" bs=16M iflag=fullblock conv=fsync status=none &&
            blockdev --rereadpt "$device" && udevadm settle &&
            cmp --bytes="$capacity" "$device" "$backup" &&
            inspect_original "$log_dir/original-pool-inspect-restored.log"; then
            restore_verified=true
            original_verified=true
            record_event "restore-verified bytes=$capacity pool=$original_pool_id filesystem=littlefs mountable=$original_mountable"
        else
            cleanup_result=1
            record_event "restore-failed"
        fi
    elif [[ $device_read_only == true ]]; then
        if ! check_identity || ! set_device_writable; then
            cleanup_result=1
        fi
    fi
    if [[ $cleanup_result -eq 0 && $test_succeeded == true && $restore_verified == true && $keep_backup == 0 ]]; then
        if rm -f -- "$backup"; then
            record_event "backup-removed path=$backup"
        else
            cleanup_result=1
        fi
    fi
    {
        echo "profile=scheduled-blob-pool-fio"
        echo "source_profile=synthetic-single-physical-device"
        echo "device=$device"
        echo "serial=$expected_serial"
        echo "original_pool_id=$original_pool_id"
        echo "original_mountable=$original_mountable"
        echo "scheduled_pool_id=$scheduled_pool_id"
        echo "backup=$backup"
        echo "capacity=$capacity"
        echo "slice_size=$slice_size"
        echo "loop_count=${#loops[@]}"
        for index in "${!loops[@]}"; do
            echo "loop_$index=${loops[$index]} offset=${offsets[$index]:-unknown} size=$slice_size"
        done
        echo "backup_ready=$backup_ready"
        echo "device_modified=$device_modified"
        echo "loops_detached=$loops_detached"
        echo "test_succeeded=$test_succeeded"
        echo "restore_verified=$restore_verified"
        echo "original_before_verified=$original_before_verified"
        echo "original_verified=$original_verified"
        echo "keep_backup=$keep_backup"
        echo "command_rc=$result"
        echo "cleanup_rc=$cleanup_result"
    } >"$log_dir/lifecycle.log"

    if [[ $cleanup_result -ne 0 ]]; then
        echo "scheduled Blob Pool restoration failed; backup retained at $backup" >&2
        exit 1
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

record_event "start profile=scheduled-blob-pool-fio source=synthetic-single-physical-device"
: >"$log_dir/device-holders.log"
check_identity
require_idle_device
[[ ! -e $backup && ! -L $backup ]] || {
    echo "refusing to overwrite backup: $backup" >&2
    exit 2
}
backup_dir=$(dirname "$backup")
[[ -d $backup_dir && -w $backup_dir ]] || {
    echo "backup directory is not writable: $backup_dir" >&2
    exit 2
}
capacity=$(blockdev --getsize64 "$device")
minimum_slice_size=$((3 * 1024 * 1024 * 1024))
((capacity / 3 >= minimum_slice_size)) || {
    echo "raw device is too small for three scheduled benchmark slices" >&2
    exit 2
}
available=$(df --output=avail -B1 "$backup_dir")
available=${available##*$'\n'}
available=${available//[[:space:]]/}
if [[ ! $available =~ ^[0-9]+$ ]] || ((available <= capacity)); then
    echo "backup filesystem requires more than $capacity bytes free" >&2
    exit 2
fi
backup_source=$(findmnt --noheadings --output SOURCE --target "$backup_dir")
while read -r descendant; do
    [[ $backup_source != "$descendant" ]] || {
        echo "backup directory must not reside on the raw device" >&2
        exit 2
    }
done < <(lsblk --noheadings --paths --raw --output NAME "$device")

inspect_original "$log_dir/original-pool-inspect-before.log"
original_before_verified=true
record_event "original-verified pool=$original_pool_id filesystem=littlefs mountable=$original_mountable"
set_device_read_only
record_event "backup-start path=$backup bytes=$capacity"
dd if="$device" of="$backup" bs=16M iflag=fullblock oflag=nofollow conv=sparse,fsync,excl status=none
[[ $(stat --format=%s "$backup") -eq $capacity ]] || {
    echo "raw-device backup image has the wrong size" >&2
    exit 1
}
cmp --bytes="$capacity" "$device" "$backup"
backup_ready=true
record_event "backup-verified path=$backup bytes=$capacity cmp=full"

check_identity
require_idle_device
[[ $(blockdev --getro "$device") == 1 ]]
set_device_writable
check_identity
require_idle_device
device_modified=true
record_event "modification-start wipefs"
wipefs --all --lock=yes "$device"
blockdev --rereadpt "$device"
udevadm settle
check_identity
require_idle_device
record_event "modification-continue blkdiscard-zeroout"
blkdiscard --zeroout "$device"
blockdev --rereadpt "$device"
udevadm settle
check_identity
require_idle_device

slice_size=$(((capacity / 3 / 1048576) * 1048576))
((slice_size > 0 && slice_size % 1048576 == 0 && slice_size * 3 <= capacity))
declare -A loop_ids=()
canonical_device=$(readlink -f -- "$device")
previous_end=0
for index in 0 1 2; do
    offset=$((index * slice_size))
    ((offset >= previous_end && offset + slice_size <= capacity))
    loop=$(losetup --find --show --sector-size 4096 --offset "$offset" --sizelimit "$slice_size" "$device")
    loops+=("$loop")
    offsets+=("$offset")

    backing_file=$(losetup --noheadings --raw --output BACK-FILE "$loop")
    actual_offset=$(losetup --noheadings --raw --output OFFSET "$loop")
    actual_limit=$(losetup --noheadings --raw --output SIZELIMIT "$loop")
    loop_id=$(lsblk --nodeps --noheadings --output MAJ:MIN "$loop" | tr -d '[:space:]')
    [[ $(readlink -f -- "$backing_file") == "$canonical_device" ]]
    [[ $actual_offset -eq $offset && $actual_limit -eq $slice_size ]]
    [[ $(blockdev --getsize64 "$loop") -eq $slice_size ]]
    [[ $(blockdev --getss "$loop") -eq 4096 ]]
    [[ $(blockdev --getro "$loop") -eq 0 && -w $loop ]]
    [[ -z ${loop_ids[$loop_id]+present} ]] || {
        echo "duplicate loop device identity: $loop_id" >&2
        exit 1
    }
    loop_ids[$loop_id]=$loop
    previous_end=$((offset + slice_size))
    record_event "loop-attached index=$index loop=$loop backing=$canonical_device offset=$offset size=$slice_size sector_size=4096 writable=yes"
done
[[ ${#loops[@]} -eq 3 && ${#loop_ids[@]} -eq 3 ]]
mapfile -t associated < <(losetup --associated "$device" --noheadings --raw --output NAME)
[[ ${#associated[@]} -eq 3 ]] || {
    echo "expected exactly three loop devices backed by $device" >&2
    exit 1
}
declare -A expected_loops=()
for loop in "${loops[@]}"; do expected_loops[$loop]=true; done
for loop in "${associated[@]}"; do
    [[ ${expected_loops[$loop]:-false} == true ]] || {
        echo "unexpected loop device is backed by $device: $loop" >&2
        exit 1
    }
done

device_args=()
for loop in "${loops[@]}"; do device_args+=(--device "$loop"); done
label=synthetic-single-device-scheduled-blob-fio
"$cli" pool plan-create "${device_args[@]}" --profile scheduled-replicated \
    --filesystem blob --name-profile portable-v1 --label "$label" >"$log_dir/scheduled-plan.log"
grep -q '^Profile: scheduled-replicated$' "$log_dir/scheduled-plan.log"
grep -q '^Devices: 3$' "$log_dir/scheduled-plan.log"
grep -q '^Filesystem: blob$' "$log_dir/scheduled-plan.log"
grep -q '^Name profile: portable-v1$' "$log_dir/scheduled-plan.log"
grep -q '^Plan: ready$' "$log_dir/scheduled-plan.log"
token=$(grep '^Confirm token: ' "$log_dir/scheduled-plan.log")
token=${token#Confirm token: }
[[ $token =~ ^[0-9a-f]{64}$ ]] || {
    echo "scheduled Blob Pool plan did not return a confirmation token" >&2
    exit 1
}
"$cli" pool create "${device_args[@]}" --profile scheduled-replicated \
    --filesystem blob --name-profile portable-v1 --label "$label" --confirm "$token" \
    >"$log_dir/scheduled-create.log"
scheduled_pool_id=$(grep '^Created pool: ' "$log_dir/scheduled-create.log")
scheduled_pool_id=${scheduled_pool_id#Created pool: }
[[ $scheduled_pool_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "scheduled Blob Pool creation did not return a Pool ID" >&2
    exit 1
}

"$cli" pool inspect "${device_args[@]}" >"$log_dir/scheduled-inspect.log"
grep -q "^Pool: $scheduled_pool_id$" "$log_dir/scheduled-inspect.log"
grep -q '^Filesystem: blob$' "$log_dir/scheduled-inspect.log"
grep -q '^Profile: scheduled-replicated$' "$log_dir/scheduled-inspect.log"
grep -q '^Members: 3/3$' "$log_dir/scheduled-inspect.log"
grep -q '^Data policy: read_write$' "$log_dir/scheduled-inspect.log"
grep -q '^Mountable: yes$' "$log_dir/scheduled-inspect.log"
for loop in "${loops[@]}"; do
    grep -Eq "^Member: $loop \\((authority|active-voter)\\)$" "$log_dir/scheduled-inspect.log"
done
record_event "scheduled-pool-created pool=$scheduled_pool_id members=3 profile=scheduled-replicated filesystem=blob"

bash test/scheduled-blob-pool-fuse-fio.sh "$cli" "$scheduled_pool_id" "${loops[@]}"
test_succeeded=true
record_event "benchmark-passed pool=$scheduled_pool_id source=synthetic-single-physical-device"
echo "synthetic single-device scheduled Blob Pool fio passed; restoring $original_pool_id"
