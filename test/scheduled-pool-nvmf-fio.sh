#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "usage: scheduled-pool-nvmf-fio.sh CLI DEVICE SERIAL" >&2
    exit 2
}

cli=$1
device=$2
expected_serial=$3
confirmation=${ZETTIDE_SCHEDULED_POOL_NVMF_FIO_CONFIRM:-}
target=${ZETTIDE_SCHEDULED_POOL_NVMF_TARGET:?ZETTIDE_SCHEDULED_POOL_NVMF_TARGET is required}
read_policy=${ZETTIDE_SCHEDULED_POOL_NVMF_READ_POLICY:-first_available}
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
loops=()
offsets=()
capacity=0
slice_size=0
pool_id=""
loops_detached=true
test_succeeded=false

[[ $EUID -eq 0 ]] || { echo "scheduled Pool NVMe-oF fio requires root" >&2; exit 2; }
[[ $confirmation == "DESTROY:$device:$expected_serial" ]] || {
    echo "scheduled Pool destructive confirmation mismatch" >&2
    exit 2
}
[[ $read_policy == first_available || $read_policy == quorum ]] || {
    echo "read policy must be first_available or quorum" >&2
    exit 2
}
for command in blkdiscard blockdev date fuser grep jq losetup lsblk readlink tr udevadm wipefs; do
    command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }
done
[[ -x $cli && -x $target && -b $device ]] || {
    echo "CLI, target, or block device is unavailable" >&2
    exit 2
}

mkdir -p "$log_dir"
events_log=$log_dir/lifecycle-events.log
: >"$events_log"

record_event() {
    printf '%s %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$events_log"
}

check_identity() {
    local actual_type actual_serial
    actual_type=$(lsblk --nodeps --noheadings --output TYPE "$device" | tr -d '[:space:]')
    actual_serial=$(lsblk --nodeps --json --output SERIAL "$device" |
        jq --exit-status --raw-output '.blockdevices | if length == 1 then .[0].serial else empty end')
    [[ $actual_type == disk && $actual_serial == "$expected_serial" ]] || {
        echo "whole-disk identity mismatch: $device ($actual_type, $actual_serial)" >&2
        return 1
    }
}

require_idle_device() {
    local path kernel_name holder_dir
    local -a paths associated
    mapfile -t associated < <(losetup --associated "$device" --noheadings --raw --output NAME)
    ((${#associated[@]} == 0)) || { echo "device has associated loops: ${associated[*]}" >&2; return 1; }
    mapfile -t paths < <(lsblk --noheadings --paths --raw --output NAME "$device")
    ((${#paths[@]} > 0)) || return 1
    if lsblk --noheadings --raw --output MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
        echo "device has mounted descendants" >&2
        return 1
    fi
    for path in "${paths[@]}"; do
        if fuser "$path" >>"$log_dir/device-holders.log" 2>&1; then
            echo "device is used by another process: $path" >&2
            return 1
        fi
        kernel_name=$(lsblk --nodeps --noheadings --output KNAME "$path" | tr -d '[:space:]')
        holder_dir=/sys/class/block/$kernel_name/holders
        if [[ ! -d $holder_dir ]] || compgen -G "$holder_dir/*" >/dev/null; then
            echo "device has kernel holders: $path" >&2
            return 1
        fi
    done
}

detach_loops() {
    local index loop backing actual_offset actual_limit expected_offset status=0
    local canonical_device
    local -a remaining
    canonical_device=$(readlink -f -- "$device")
    for index in "${!loops[@]}"; do
        loop=${loops[$index]}
        expected_offset=${offsets[$index]}
        losetup "$loop" >/dev/null 2>&1 || continue
        backing=$(losetup --noheadings --raw --output BACK-FILE "$loop")
        actual_offset=$(losetup --noheadings --raw --output OFFSET "$loop")
        actual_limit=$(losetup --noheadings --raw --output SIZELIMIT "$loop")
        if [[ $(readlink -f -- "$backing") != "$canonical_device" ||
            $actual_offset -ne $expected_offset || $actual_limit -ne $slice_size ]]; then
            echo "refusing to detach loop whose identity changed: $loop" >&2
            status=1
            continue
        fi
        losetup --detach "$loop" || status=1
    done
    udevadm settle || status=1
    mapfile -t remaining < <(losetup --associated "$device" --noheadings --raw --output NAME)
    if ((${#remaining[@]} != 0)); then
        echo "unexpected loop devices remain associated with $device: ${remaining[*]}" >&2
        status=1
    fi
    loops=()
    offsets=()
    [[ $status -eq 0 ]] && loops_detached=true || loops_detached=false
    return "$status"
}

finish() {
    local command_rc=$? cleanup_rc=0
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    detach_loops || cleanup_rc=1
    {
        echo "profile=nvmf-scheduled-pool-rxe-fio"
        echo "device=$device"
        echo "serial=$expected_serial"
        echo "pool_id=$pool_id"
        echo "capacity=$capacity"
        echo "slice_size=$slice_size"
        echo "loops_detached=$loops_detached"
        echo "test_succeeded=$test_succeeded"
        echo "command_rc=$command_rc"
        echo "cleanup_rc=$cleanup_rc"
    } >"$log_dir/lifecycle.log"
    record_event "cleanup loops_detached=$loops_detached test_succeeded=$test_succeeded command_rc=$command_rc cleanup_rc=$cleanup_rc"
    [[ $cleanup_rc -eq 0 ]] || exit 1
    exit "$command_rc"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

attach_slices() {
    local index offset loop backing actual_offset actual_limit loop_id previous_end=0
    local canonical_device
    declare -A loop_ids=()
    canonical_device=$(readlink -f -- "$device")
    loops=()
    offsets=()
    loops_detached=false
    for index in 0 1 2; do
        offset=$((index * slice_size))
        ((offset >= previous_end && offset + slice_size <= capacity))
        loop=$(losetup --find --show --sector-size 4096 --offset "$offset" --sizelimit "$slice_size" "$device")
        loops+=("$loop")
        offsets+=("$offset")
        backing=$(losetup --noheadings --raw --output BACK-FILE "$loop")
        actual_offset=$(losetup --noheadings --raw --output OFFSET "$loop")
        actual_limit=$(losetup --noheadings --raw --output SIZELIMIT "$loop")
        loop_id=$(lsblk --nodeps --noheadings --output MAJ:MIN "$loop" | tr -d '[:space:]')
        [[ $(readlink -f -- "$backing") == "$canonical_device" ]]
        [[ $actual_offset -eq $offset && $actual_limit -eq $slice_size ]]
        [[ $(blockdev --getsize64 "$loop") -eq $slice_size && $(blockdev --getss "$loop") -eq 4096 ]]
        [[ $(blockdev --getro "$loop") -eq 0 && -w $loop && -z ${loop_ids[$loop_id]+set} ]]
        loop_ids[$loop_id]=$loop
        previous_end=$((offset + slice_size))
        record_event "loop-attached index=$index loop=$loop offset=$offset size=$slice_size"
    done
    [[ ${#loops[@]} -eq 3 && ${#loop_ids[@]} -eq 3 ]]
}

inspect_scheduled_pool() {
    local output=$1 loop
    local -a device_args=()
    for loop in "${loops[@]}"; do device_args+=(--device "$loop"); done
    "$cli" pool inspect "${device_args[@]}" >"$output" || return 1
    grep -q '^Profile: scheduled-replicated$' "$output" || return 1
    grep -q '^Data mode: blob$' "$output" || return 1
    grep -q '^Members: 3/3$' "$output" || return 1
    grep -q '^Data policy: read_write$' "$output" || return 1
    pool_id=$(grep '^Pool: ' "$output") || return 1
    pool_id=${pool_id#Pool: }
    [[ $pool_id =~ ^[0-9a-f]{32}$ ]] || return 1
    for loop in "${loops[@]}"; do
        grep -Eq "^Member: $loop \\((authority|active-voter)\\)$" "$output" || return 1
    done
}

create_scheduled_pool() {
    local token loop label=synthetic-single-device-scheduled-nvmf
    local -a device_args=()
    for loop in "${loops[@]}"; do device_args+=(--device "$loop"); done
    "$cli" pool plan-create "${device_args[@]}" --profile scheduled-replicated \
        --name-profile portable-v1 --label "$label" >"$log_dir/scheduled-plan.log"
    grep -q '^Profile: scheduled-replicated$' "$log_dir/scheduled-plan.log"
    grep -q '^Devices: 3$' "$log_dir/scheduled-plan.log"
    grep -q '^Data mode: blob$' "$log_dir/scheduled-plan.log"
    grep -q '^Plan: ready$' "$log_dir/scheduled-plan.log"
    token=$(grep '^Confirm token: ' "$log_dir/scheduled-plan.log")
    token=${token#Confirm token: }
    [[ $token =~ ^[0-9a-f]{64}$ ]]
    "$cli" pool create "${device_args[@]}" --profile scheduled-replicated \
        --name-profile portable-v1 --label "$label" --confirm "$token" >"$log_dir/scheduled-create.log"
    inspect_scheduled_pool "$log_dir/scheduled-inspect-created.log"
}

: >"$log_dir/device-holders.log"
check_identity
require_idle_device
capacity=$(blockdev --getsize64 "$device")
slice_size=$(((capacity / 3 / 1048576) * 1048576))
((slice_size >= 3 * 1024 * 1024 * 1024 && slice_size % 1048576 == 0 && slice_size * 3 <= capacity))
attach_slices
if inspect_scheduled_pool "$log_dir/scheduled-inspect-reuse.log"; then
    record_event "pool-reused pool=$pool_id profile=scheduled-replicated members=3"
else
    record_event "pool-reuse-rejected"
    detach_loops
    check_identity
    require_idle_device
    wipefs --all --lock=yes "$device"
    blockdev --rereadpt "$device"
    udevadm settle
    check_identity
    require_idle_device
    blkdiscard --zeroout "$device"
    blockdev --rereadpt "$device"
    udevadm settle
    check_identity
    require_idle_device
    attach_slices
    create_scheduled_pool
    record_event "pool-created pool=$pool_id profile=scheduled-replicated members=3"
fi

bash test/spdk-nvmf-fio.sh "$target" "$log_dir/nvmf-ready" "$log_dir/nvmf" \
    "$pool_id" "$read_policy" "${loops[@]}"
test_succeeded=true
record_event "benchmark-passed pool=$pool_id"
