#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 4 || $# -eq 5 ]] || {
    echo "usage: physical-pool-fio.sh CLI DEVICE SERIAL POOL_ID [littlefs|blob]" >&2
    exit 2
}

cli=$1
device=$2
expected_serial=$3
expected_pool_id=$4
expected_filesystem=${5:-littlefs}
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
single_size=${ZETTIDE_POOL_FIO_SINGLE_SIZE:-2G}
multi_size=${ZETTIDE_POOL_FIO_MULTI_SIZE:-512M}
runtime=${ZETTIDE_POOL_FIO_RUNTIME:-20}
ramp_time=${ZETTIDE_POOL_FIO_RAMP_TIME:-5}
frontend=${ZETTIDE_POOL_FIO_FRONTEND:-fuse}
ganesha_build=${ZETTIDE_GANESHA_BUILD_DIR:-}
nfs_stable_write_batch_us=${ZETTIDE_NFS_STABLE_WRITE_BATCH_US:-20000}
nfs_nconnect=${ZETTIDE_NFS_NCONNECT:-1}
nfs_rpc_ioq_thrd_min=${ZETTIDE_NFS_RPC_IOQ_THRD_MIN:-2}
nfs_rpc_ioq_thrd_max=${ZETTIDE_NFS_RPC_IOQ_THRD_MAX:-16}
nfs_perf_case=${ZETTIDE_NFS_PERF_CASE:-}
nfs_perf_frequency=${ZETTIDE_NFS_PERF_FREQUENCY:-199}

[[ $EUID -eq 0 ]] || {
    echo "physical Pool fio requires root" >&2
    exit 2
}
[[ $runtime =~ ^[1-9][0-9]*$ && $ramp_time =~ ^[0-9]+$ ]] || {
    echo "fio runtime and ramp time must be integer seconds" >&2
    exit 2
}
[[ $expected_filesystem == littlefs || $expected_filesystem == blob ]] || {
    echo "unsupported Pool filesystem: $expected_filesystem" >&2
    exit 2
}
[[ $frontend == fuse || $frontend == nfs ]] || {
    echo "unsupported Pool fio frontend: $frontend" >&2
    exit 2
}
[[ $nfs_stable_write_batch_us =~ ^[0-9]+$ ]] && ((nfs_stable_write_batch_us <= 999999)) || {
    echo "ZETTIDE_NFS_STABLE_WRITE_BATCH_US must be between 0 and 999999" >&2
    exit 2
}
[[ $nfs_nconnect =~ ^[1-9][0-9]*$ ]] && ((nfs_nconnect <= 16)) || {
    echo "ZETTIDE_NFS_NCONNECT must be between 1 and 16" >&2
    exit 2
}
[[ $nfs_rpc_ioq_thrd_min =~ ^[1-9][0-9]*$ && $nfs_rpc_ioq_thrd_max =~ ^[1-9][0-9]*$ ]] &&
    ((nfs_rpc_ioq_thrd_min >= 2 && nfs_rpc_ioq_thrd_min <= nfs_rpc_ioq_thrd_max)) || {
    echo "NFS RPC IOQ thread limits must satisfy 2 <= min <= max" >&2
    exit 2
}
[[ $nfs_perf_frequency =~ ^[1-9][0-9]*$ ]] || {
    echo "ZETTIDE_NFS_PERF_FREQUENCY must be a positive integer" >&2
    exit 2
}
[[ -z $nfs_perf_case || $frontend == nfs ]] || {
    echo "ZETTIDE_NFS_PERF_CASE requires the NFS frontend" >&2
    exit 2
}
commands=(fio lsblk mountpoint timeout)
if [[ $frontend == fuse ]]; then
    commands+=(fusermount3 setsid)
else
    commands+=(mount mount.nfs pgrep python3 rpcbind rpcinfo umount)
    [[ -z $nfs_perf_case ]] || commands+=(perf)
    [[ -n $ganesha_build ]] || {
        echo "ZETTIDE_GANESHA_BUILD_DIR is required for the NFS frontend" >&2
        exit 2
    }
fi
for command in "${commands[@]}"; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done

mkdir -p "$log_dir"
work=$(mktemp -d "${TMPDIR:-/tmp}/zettide-physical-pool-fio.XXXXXX")
mountpoint_path="$work/mount"
mkdir "$mountpoint_path"
mount_pid=""
ganesha="$ganesha_build/ganesha.nfsd"
ganesha_module="$ganesha_build/FSAL/FSAL_ZETTIDE/libfsalzettide.so"
ganesha_pid=""
ganesha_launcher_pid=""
ganesha_pid_file="$work/ganesha.pid"
ganesha_config="$work/ganesha.conf"
perf_pid=""
perf_data=""
perf_recorded=false
rpcbind_started=false
rpcbind_pid=""
fio_command=(fio)
if [[ $frontend == nfs ]]; then
    fio_timeout=$((runtime + ramp_time + 120))
    ((fio_timeout >= 600)) || fio_timeout=600
    fio_command=(timeout --kill-after=10s "${fio_timeout}s" fio)
fi

choose_port() {
    python3 - <<'PY'
import socket

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

check_identity() {
    local actual_type actual_serial
    actual_type=$(lsblk --nodeps --noheadings --output TYPE "$device" | tr -d '[:space:]')
    actual_serial=$(lsblk --nodeps --noheadings --output SERIAL "$device" | tr -d '[:space:]')
    [[ $actual_type == disk && $actual_serial == "$expected_serial" ]] || {
        echo "physical Pool identity changed: $device ($actual_type, $actual_serial)" >&2
        return 1
    }
}

stop_pool_mount() {
    if [[ $frontend == nfs ]]; then
        if mountpoint -q "$mountpoint_path"; then
            timeout --kill-after=2s 30s umount "$mountpoint_path" >/dev/null 2>&1 ||
                timeout --kill-after=2s 10s umount -fl "$mountpoint_path" >/dev/null 2>&1 || true
        fi
        if [[ -n $ganesha_pid ]]; then
            kill -TERM "$ganesha_pid" 2>/dev/null || true
            for ((attempt = 0; attempt < 300; attempt++)); do
                kill -0 "$ganesha_pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -0 "$ganesha_pid" 2>/dev/null && kill -KILL "$ganesha_pid" 2>/dev/null || true
            ganesha_pid=""
        fi
        if [[ -n $ganesha_launcher_pid ]]; then
            wait "$ganesha_launcher_pid" 2>/dev/null || true
            ganesha_launcher_pid=""
        fi
        if mountpoint -q "$mountpoint_path"; then
            timeout --kill-after=2s 10s umount -fl "$mountpoint_path" >/dev/null 2>&1 || true
        fi
        ! mountpoint -q "$mountpoint_path"
        return
    fi
    if mountpoint -q "$mountpoint_path"; then
        timeout --kill-after=2s 30s "$cli" unmount "$mountpoint_path" >/dev/null 2>&1 ||
            timeout --kill-after=2s 10s fusermount3 -uz "$mountpoint_path" >/dev/null 2>&1 || true
    fi
    if [[ -n $mount_pid ]]; then
        for ((attempt = 0; attempt < 300; attempt++)); do
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
    ! mountpoint -q "$mountpoint_path"
}

stop_pool_mount_clean() {
    if [[ $frontend == nfs ]]; then
        mountpoint -q "$mountpoint_path" || return 1
        if ! timeout --kill-after=2s 30s umount "$mountpoint_path"; then
            timeout --kill-after=2s 10s umount -fl "$mountpoint_path" || true
            return 1
        fi
        [[ -n $ganesha_pid ]] || return 1
        kill -TERM "$ganesha_pid"
        for ((attempt = 0; attempt < 300; attempt++)); do
            kill -0 "$ganesha_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$ganesha_pid" 2>/dev/null && return 1
        ganesha_pid=""
        wait "$ganesha_launcher_pid"
        ganesha_launcher_pid=""
        ! mountpoint -q "$mountpoint_path"
        return
    fi
    mountpoint -q "$mountpoint_path" || return 1
    timeout --kill-after=2s 30s "$cli" unmount "$mountpoint_path" >/dev/null
    for ((attempt = 0; attempt < 300; attempt++)); do
        kill -0 "$mount_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$mount_pid" 2>/dev/null && return 1
    wait "$mount_pid"
    mount_pid=""
    ! mountpoint -q "$mountpoint_path"
}

start_pool_mount() {
    local log=$1
    shift
    : >"$log"
    if [[ $frontend == nfs ]]; then
        rm -f "$ganesha_pid_file"
        "$ganesha" -F -f "$ganesha_config" -L "$log" -p "$ganesha_pid_file" -N EVENT \
            >"$log.console" 2>&1 &
        ganesha_launcher_pid=$!
        ganesha_pid=$ganesha_launcher_pid
        for ((attempt = 0; attempt < 300; attempt++)); do
            if [[ -s $ganesha_pid_file ]]; then
                ganesha_pid=$(<"$ganesha_pid_file")
                if kill -0 "$ganesha_pid" 2>/dev/null &&
                    rpcinfo -p 127.0.0.1 2>/dev/null |
                        grep -Eq "^[[:space:]]*100003[[:space:]]+3[[:space:]]+tcp[[:space:]]+$nfs_port([[:space:]]|$)"; then
                    timeout --kill-after=2s 30s mount -t nfs \
                        -o "vers=3,nolock,proto=tcp,port=$nfs_port,mountport=$mnt_port,rsize=1048576,wsize=1048576,noatime,nconnect=$nfs_nconnect" \
                        127.0.0.1:/zettide "$mountpoint_path"
                    return
                fi
            fi
            if ! kill -0 "$ganesha_launcher_pid" 2>/dev/null; then
                cat "$log" >&2
                cat "$log.console" >&2
                return 1
            fi
            sleep 0.1
        done
        cat "$log" >&2
        cat "$log.console" >&2
        echo "NFS-Ganesha Pool mount readiness timeout" >&2
        return 1
    fi
    setsid "$cli" pool mount "$mountpoint_path" --device "$device" --allow-other --noatime "$@" \
        >"$log" 2>&1 &
    mount_pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        if mountpoint -q "$mountpoint_path"; then
            return
        fi
        if ! kill -0 "$mount_pid" 2>/dev/null; then
            cat "$log" >&2
            return 1
        fi
        sleep 0.1
    done
    cat "$log" >&2
    echo "physical Pool mount readiness timeout" >&2
    return 1
}

finish() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
        perf_pid=""
    fi
    stop_pool_mount || result=1
    if [[ $rpcbind_started == true && -n $rpcbind_pid ]]; then
        kill -TERM "$rpcbind_pid" 2>/dev/null || result=1
    fi
    if mountpoint -q "$mountpoint_path"; then
        echo "NFS mount remains active; preserving work directory: $work" >&2
        result=1
    else
        rm -rf "$work"
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT TERM

if [[ $frontend == nfs ]]; then
    [[ -x $ganesha && -f $ganesha_module ]] || {
        echo "NFS-Ganesha or FSAL_ZETTIDE is unavailable in $ganesha_build" >&2
        exit 2
    }
    nfs_port=$(choose_port)
    mnt_port=$(choose_port)
    while [[ $mnt_port == "$nfs_port" ]]; do mnt_port=$(choose_port); done
    cat >"$ganesha_config" <<EOF
NFS_Core_Param {
    NFS_Port = $nfs_port;
    MNT_Port = $mnt_port;
    Bind_Addr = 127.0.0.1;
    Protocols = 3;
    Enable_UDP = false;
    Plugins_Dir = "$ganesha_build/FSAL/FSAL_ZETTIDE";
    Allow_Set_Io_Flusher_Fail = true;
    rpc_ioq_thrdmin = $nfs_rpc_ioq_thrd_min;
    RPC_Ioq_ThrdMax = $nfs_rpc_ioq_thrd_max;
}

NFSv4 {
    RecoveryRoot = "$work";
}

EXPORT {
    Export_Id = 77;
    Path = "/zettide";
    Pseudo = "/zettide";
    Access_Type = RW;
    Squash = No_Root_Squash;
    Protocols = 3;
    Transports = TCP;
    SecType = sys;

    FSAL {
        name = ZETTIDE;
        Target = "$device";
        Writable = true;
        Stable_Write_Batch_Us = $nfs_stable_write_batch_us;
    }
}
EOF
    if ! rpcinfo -p 127.0.0.1 >/dev/null 2>&1; then
        rpcbind -w
        rpcbind_started=true
        for ((attempt = 0; attempt < 100; attempt++)); do
            rpcinfo -p 127.0.0.1 >/dev/null 2>&1 && break
            sleep 0.05
        done
        rpcinfo -p 127.0.0.1 >/dev/null 2>&1 || {
            echo "rpcbind failed to start" >&2
            exit 1
        }
        rpcbind_pid=$(pgrep -xo rpcbind)
    fi
fi

run_fio_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local jobs=$5
    local size=$6
    local file_pattern=$7
    local mount_log="$log_dir/mount-$name.log"
    local peak_inflight
    local -a fio_args=(
        "${fio_command[@]}"
        --name="$name"
        --rw="$rw"
        --bs="$block_size"
        --size="$size"
        --ioengine=io_uring
        --iodepth="$depth"
        --numjobs="$jobs"
        --direct=1
        --fallocate=none
        --allow_file_create=0
        --invalidate=1
        --group_reporting=1
        --time_based=1
        --runtime="$runtime"
        --ramp_time="$ramp_time"
        --randrepeat=0
        --norandommap=1
        --refill_buffers=1
        --percentile_list=50:95:99:99.9
        --eta=never
        --output-format=json
        --output="$log_dir/fio-$name.json"
    )
    start_pool_mount "$mount_log" --metrics
    if [[ $jobs -eq 1 ]]; then
        fio_args+=(--filename="$mountpoint_path/fio-performance/$file_pattern")
    else
        fio_args+=(--filename_format="$mountpoint_path/fio-performance/$file_pattern")
    fi
    if [[ -n $nfs_perf_case && $name == "$nfs_perf_case" ]]; then
        perf_data="$log_dir/perf-$name.data"
        perf record --quiet --freq "$nfs_perf_frequency" --call-graph fp \
            --pid "$ganesha_pid" --output "$perf_data" &
        perf_pid=$!
        perf_recorded=true
    fi
    "${fio_args[@]}"
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
        perf_pid=""
        perf report --stdio --no-children --call-graph none --percent-limit 0.1 \
            --sort=dso,symbol --input "$perf_data" >"$log_dir/perf-$name-self.txt"
        perf report --stdio --percent-limit 0.1 \
            --sort=dso,symbol --input "$perf_data" >"$log_dir/perf-$name-inclusive.txt"
    fi
    stop_pool_mount_clean
    if [[ $frontend == nfs ]]; then
        grep -q "Opened Zettide target $device (writable)" "$mount_log"
        grep -q 'zettide_write_metrics stable_writes=' "$mount_log"
        return
    fi
    grep -q '^fuse_metrics ' "$mount_log"
    if [[ $expected_filesystem == blob ]]; then
        grep -q '^pool_transport_metrics ' "$mount_log"
        ! grep -q '^pipeline_metrics ' "$mount_log"
        ! grep -q '^member_transport_metrics ' "$mount_log"
        if [[ $name == seq-read-1m-qd32-j1 ]]; then
            peak_inflight=$(grep -o 'max_inflight=[0-9]*' "$mount_log")
            peak_inflight=${peak_inflight#max_inflight=}
            ((peak_inflight > 1))
        elif [[ $name == seq-write-1m-qd32-j1 ]]; then
            peak_inflight=$(grep -o 'max_inflight=[0-9]*' "$mount_log")
            peak_inflight=${peak_inflight#max_inflight=}
            ((peak_inflight == 1))
            submitted_sqes=$(grep -o 'submitted_sqes=[0-9]*' "$mount_log")
            submitted_sqes=${submitted_sqes#submitted_sqes=}
            write_calls=$(grep -o 'write_calls=[0-9]*' "$mount_log")
            write_calls=${write_calls#write_calls=}
            ((submitted_sqes < write_calls * 128))
        fi
    else
        grep -q '^pipeline_metrics ' "$mount_log"
        grep -q '^member_transport_metrics index=0 ' "$mount_log"
    fi
}

prepare_single_file() {
    "${fio_command[@]}" \
        --name=prepare-single \
        --filename="$fio_dir/single.bin" \
        --rw=write \
        --bs=1m \
        --size="$single_size" \
        --ioengine=io_uring \
        --iodepth=32 \
        --direct=1 \
        --fallocate=none \
        --end_fsync=1 \
        --group_reporting=1 \
        --eta=never \
        --output-format=json \
        --output="$log_dir/fio-prepare-single.json"
}

prepare_multi_files() {
    "${fio_command[@]}" \
        --name=prepare-multi \
        --filename_format="$fio_dir/multi.\$jobnum.bin" \
        --numjobs=4 \
        --rw=write \
        --bs=1m \
        --size="$multi_size" \
        --ioengine=io_uring \
        --iodepth=32 \
        --direct=1 \
        --fallocate=none \
        --end_fsync=1 \
        --group_reporting=1 \
        --eta=never \
        --output-format=json \
        --output="$log_dir/fio-prepare-multi.json"
}

check_identity
"$cli" device inspect "$device" >"$log_dir/device-inspect.log"
grep -q '^Preflight: eligible$' "$log_dir/device-inspect.log"
"$cli" pool inspect --device "$device" >"$log_dir/pool-inspect-before.log"
grep -q "^Pool: $expected_pool_id$" "$log_dir/pool-inspect-before.log"
grep -q "^Filesystem: $expected_filesystem$" "$log_dir/pool-inspect-before.log"
grep -q '^Profile: unprotected$' "$log_dir/pool-inspect-before.log"
grep -q '^Data policy: read_write$' "$log_dir/pool-inspect-before.log"
grep -q '^Mountable: yes$' "$log_dir/pool-inspect-before.log"

start_pool_mount "$log_dir/mount-prepare.log"
fio_dir="$mountpoint_path/fio-performance"
mkdir -p "$fio_dir"
[[ -f $fio_dir/single.bin ]] || prepare_single_file
multi_ready=true
for job in 0 1 2 3; do
    [[ -f $fio_dir/multi.$job.bin ]] || multi_ready=false
done
[[ $multi_ready == true ]] || prepare_multi_files
stop_pool_mount_clean

run_fio_case seq-write-1m-qd32-j1 write 1m 32 1 "$single_size" single.bin
run_fio_case randwrite-4k-qd1-j1 randwrite 4k 1 1 "$single_size" single.bin
run_fio_case randwrite-4k-qd32-j1 randwrite 4k 32 1 "$single_size" single.bin
run_fio_case randwrite-4k-qd32-j4 randwrite 4k 32 4 "$multi_size" 'multi.$jobnum.bin'
run_fio_case seq-read-1m-qd32-j1 read 1m 32 1 "$single_size" single.bin
run_fio_case randread-4k-qd1-j1 randread 4k 1 1 "$single_size" single.bin
run_fio_case randread-4k-qd32-j1 randread 4k 32 1 "$single_size" single.bin
run_fio_case randread-4k-qd32-j4 randread 4k 32 4 "$multi_size" 'multi.$jobnum.bin'
[[ -z $nfs_perf_case || $perf_recorded == true ]] || {
    echo "NFS perf case was not run: $nfs_perf_case" >&2
    exit 2
}

check_identity
"$cli" pool inspect --device "$device" >"$log_dir/pool-inspect-after.log"
grep -q "^Pool: $expected_pool_id$" "$log_dir/pool-inspect-after.log"
grep -q "^Filesystem: $expected_filesystem$" "$log_dir/pool-inspect-after.log"
grep -q '^Mountable: yes$' "$log_dir/pool-inspect-after.log"
echo "physical Pool fio passed"
