#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 4 ]] || {
    echo "usage: spdk-iscsi-fio.sh TARGET READY_FILE MEMBER_FILE LOG_DIR [TARGET_ARG...]" >&2
    exit 2
}

target=$1
ready_file=$2
member_file=$3
log_dir=$4
shift 4
target_addr=${ZETTIDE_ISCSI_TARGET_ADDR:-127.0.0.1}
target_port=${ZETTIDE_ISCSI_TARGET_PORT:-3260}
target_name=iqn.2026-08.io.zettide:benchmark
portal=${target_addr}:${target_port}
expected_size=${ZETTIDE_ISCSI_EXPECTED_SIZE:-68719476736}
fio_size=${ZETTIDE_ISCSI_FIO_SIZE:-256M}
target_pid=""
device=""
logged_in=false

[[ $EUID -eq 0 ]] || {
    echo "iSCSI fio requires root" >&2
    exit 2
}
for command in blockdev fio iscsiadm lsblk modprobe udevadm; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done

cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if [[ $logged_in == true ]]; then
        iscsiadm -m node -T "$target_name" -p "$portal" --logout >/dev/null 2>&1 || result=1
    fi
    iscsiadm -m node -T "$target_name" -p "$portal" -o delete >/dev/null 2>&1 || true
    if [[ -n $target_pid ]] && kill -0 "$target_pid" 2>/dev/null; then
        kill -TERM "$target_pid" 2>/dev/null || true
        if ! wait "$target_pid"; then
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$log_dir"
rm -f "$ready_file" "$member_file"
iscsiadm -m node -T "$target_name" -p "$portal" --logout >/dev/null 2>&1 || true
iscsiadm -m node -T "$target_name" -p "$portal" -o delete >/dev/null 2>&1 || true
modprobe iscsi_tcp

"$target" "$ready_file" "$member_file" "$@" >"$log_dir/target.log" 2>&1 &
target_pid=$!
for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -f $ready_file ]] && break
    if ! kill -0 "$target_pid" 2>/dev/null; then
        wait "$target_pid" || true
        command cat "$log_dir/target.log" >&2
        exit 1
    fi
    sleep 0.01
done
[[ -f $ready_file ]] || {
    echo "iSCSI target did not become ready after 10 seconds" >&2
    command cat "$log_dir/target.log" >&2
    exit 1
}

iscsiadm -m discovery -t sendtargets -p "$portal" >"$log_dir/discovery.txt"
iscsiadm -m node -T "$target_name" -p "$portal" --login
logged_in=true
udevadm settle
for ((attempt = 0; attempt < 1000; attempt++)); do
    device=$(readlink -f "/dev/disk/by-path/ip-${portal}-iscsi-${target_name}-lun-0" 2>/dev/null || true)
    [[ -b $device ]] && break
    sleep 0.01
done
[[ -b $device ]] || {
    echo "iSCSI LUN did not appear" >&2
    iscsiadm -m session -P 3 >"$log_dir/session.txt" || true
    exit 1
}

lsblk --bytes --output NAME,KNAME,TYPE,SIZE,MODEL,SERIAL "$device" >"$log_dir/lsblk.txt"
[[ $(blockdev --getsize64 "$device") -eq $expected_size ]]
[[ $(lsblk --nodeps --noheadings --output SERIAL "$device" | xargs) == ZettideCatalogBenchmark0 ]]
fio --name=iscsi-verify --filename="$device" --rw=randwrite --bs=4k --size="$fio_size" \
    --ioengine=io_uring --iodepth=32 --direct=1 --verify=crc32c --do_verify=1 \
    --verify_fatal=1 --randrepeat=1 --group_reporting=1 --eta=never \
    --output-format=json --output="$log_dir/fio-iscsi-verify.json"
