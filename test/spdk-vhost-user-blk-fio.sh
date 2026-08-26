#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 6 ]] || {
    echo "usage: spdk-vhost-user-blk-fio.sh TARGET READY_FILE LOG_DIR POOL_ID READ_POLICY DEVICE..." >&2
    exit 2
}

target=$1
ready_file=$2
log_dir=$3
pool_id=$4
read_policy=$5
shift 5
devices=("$@")

runtime=${ZETTIDE_VHOST_FIO_RUNTIME:-20}
ramp_time=${ZETTIDE_VHOST_FIO_RAMP_TIME:-5}
fio_size=${ZETTIDE_VHOST_FIO_SIZE:-1G}
fio_case=${ZETTIDE_VHOST_FIO_CASE:-}
guest_vcpus=${ZETTIDE_VHOST_GUEST_VCPUS:-4}
queues=${ZETTIDE_VHOST_QUEUES:-1}
ssh_port=${ZETTIDE_VHOST_SSH_PORT:-10022}
reactor_count=${ZETTIDE_NVMF_REACTOR_COUNT:-1}
controller_count=${ZETTIDE_VHOST_CONTROLLER_COUNT:-$reactor_count}
perf_case=${ZETTIDE_VHOST_PERF_CASE:-}
perf_frequency=${ZETTIDE_VHOST_PERF_FREQUENCY:-199}
vcpu_cpu_base=${ZETTIDE_VHOST_VCPU_CPU_BASE:-}
target_gdb=${ZETTIDE_VHOST_TARGET_GDB:-0}
storage_transport=${ZETTIDE_POOL_DATA_STORAGE_TRANSPORT:-linux}
benchmark_mode=${ZETTIDE_POOL_DATA_BENCHMARK_MODE:-pool}
base_image=${ZETTIDE_VHOST_BASE_IMAGE:?ZETTIDE_VHOST_BASE_IMAGE is required}
target_pid=""
qemu_pid=""
guest_ready=false
benchmark_completed=false
work_dir=""
socket_dir=""
socket_paths=()
monitor_pids=()
perf_pid=""
perf_data=""
deferred_signal=0

case $fio_case in
    "" | seq-read-1m-qd32-j1 | seq-read-128k-qd1-j1 | randread-4k-qd1-j1 | randread-4k-qd32-j1 | randread-4k-qd32-j4 | randread-4k-qd32-j16 | randread-4k-qd256-j1-per-device) ;;
    *)
        echo "unknown vhost-user-blk fio case: $fio_case" >&2
        exit 2
        ;;
esac
[[ $benchmark_mode == pool || $benchmark_mode == raw_nvme ]] || {
    echo "benchmark mode must be pool or raw_nvme" >&2
    exit 2
}
if [[ $benchmark_mode == raw_nvme ]]; then
    [[ $storage_transport == spdk_nvme_pcie && $controller_count -eq 2 &&
        $fio_case == randread-4k-qd256-j1-per-device ]] || {
        echo "raw NVMe mode requires SPDK PCIe, two controllers, and randread-4k-qd256-j1-per-device" >&2
        exit 2
    }
elif [[ $fio_case == randread-4k-qd256-j1-per-device ]]; then
    echo "randread-4k-qd256-j1-per-device requires raw NVMe mode" >&2
    exit 2
fi

[[ $EUID -eq 0 ]] || {
    echo "vhost-user-blk fio requires root" >&2
    exit 2
}
[[ -c /dev/kvm ]] || {
    echo "/dev/kvm is required" >&2
    exit 2
}
[[ -r $base_image ]] || {
    echo "base image is not readable: $base_image" >&2
    exit 2
}
[[ $runtime =~ ^[1-9][0-9]*$ ]] || { echo "invalid fio runtime: $runtime" >&2; exit 2; }
[[ $ramp_time =~ ^[0-9]+$ ]] || { echo "invalid fio ramp time: $ramp_time" >&2; exit 2; }
[[ $fio_size =~ ^[1-9][0-9]*([kKmMgGtTpP][iI]?[bB]?)?$ ]] || { echo "invalid fio size: $fio_size" >&2; exit 2; }
[[ $guest_vcpus =~ ^[1-9][0-9]*$ ]] || { echo "invalid guest vCPU count: $guest_vcpus" >&2; exit 2; }
[[ $queues =~ ^[1-9][0-9]*$ ]] || { echo "invalid vhost queue count: $queues" >&2; exit 2; }
if [[ ! $ssh_port =~ ^[0-9]+$ ]] || ((ssh_port < 1 || ssh_port > 65535)); then
    echo "invalid SSH port: $ssh_port" >&2
    exit 2
fi
[[ $reactor_count =~ ^[1-9][0-9]*$ ]] || { echo "invalid reactor count: $reactor_count" >&2; exit 2; }
[[ $controller_count =~ ^[1-9][0-9]*$ ]] || { echo "invalid vhost controller count: $controller_count" >&2; exit 2; }
[[ $perf_frequency =~ ^[1-9][0-9]*$ ]] || { echo "invalid perf frequency: $perf_frequency" >&2; exit 2; }
[[ -z $vcpu_cpu_base || $vcpu_cpu_base =~ ^[0-9]+$ ]] || { echo "invalid vCPU CPU base: $vcpu_cpu_base" >&2; exit 2; }
[[ $target_gdb == 0 || $target_gdb == 1 ]] || { echo "invalid target gdb mode: $target_gdb" >&2; exit 2; }
if [[ -n $perf_case && $perf_case != "$fio_case" ]]; then
    echo "perf case must match the selected fio case" >&2
    exit 2
fi
((queues <= guest_vcpus)) || {
    echo "vhost queue count must not exceed guest vCPU count" >&2
    exit 2
}
((controller_count <= reactor_count && controller_count <= queues && queues % controller_count == 0)) || {
    echo "vhost controller count must divide the queue count and not exceed reactors or queues" >&2
    exit 2
}
queues_per_controller=$((queues / controller_count))

qemu_command=""
if command -v qemu-system-x86_64 >/dev/null; then
    qemu_command=$(command -v qemu-system-x86_64)
elif command -v qemu-kvm >/dev/null; then
    qemu_command=$(command -v qemu-kvm)
else
    echo "qemu-system-x86_64 or qemu-kvm is required" >&2
    exit 2
fi
for command_name in qemu-img cloud-localds ssh scp ssh-keygen jq pidstat mpstat iostat findmnt; do
    command -v "$command_name" >/dev/null || {
        echo "$command_name is required" >&2
        exit 2
    }
done
if [[ -n $perf_case ]]; then
    command -v perf >/dev/null || {
        echo "perf is required when a perf case is selected" >&2
        exit 2
    }
fi
if [[ -n $vcpu_cpu_base ]]; then
    command -v taskset >/dev/null || {
        echo "taskset is required when vCPU affinity is selected" >&2
        exit 2
    }
    ((vcpu_cpu_base + guest_vcpus <= $(nproc))) || {
        echo "vCPU affinity exceeds the host CPU count" >&2
        exit 2
    }
fi
if [[ $target_gdb == 1 ]]; then
    command -v gdb >/dev/null || {
        echo "gdb is required when target debugging is enabled" >&2
        exit 2
    }
fi

process_running() {
    local pid=$1
    local state=""
    kill -0 "$pid" 2>/dev/null || return 1
    if [[ -r /proc/$pid/stat ]]; then
        read -r _ _ state _ <"/proc/$pid/stat" || true
        [[ $state != Z ]] || return 1
    fi
}

stop_process() {
    local name=$1
    local pid=$2
    local deadline

    process_running "$pid" || {
        wait "$pid" 2>/dev/null || true
        return 0
    }
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while process_running "$pid" && ((SECONDS < deadline)); do
        sleep 0.1
    done
    if process_running "$pid"; then
        echo "$name did not stop after TERM; sending KILL" >&2
        kill -KILL "$pid" 2>/dev/null || true
        deadline=$((SECONDS + 3))
        while process_running "$pid" && ((SECONDS < deadline)); do
            sleep 0.1
        done
    fi
    if process_running "$pid"; then
        echo "$name remains running after KILL" >&2
        return 1
    fi
    wait "$pid" 2>/dev/null || true
}

restore_signal_traps() {
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

begin_deferred_signals() {
    deferred_signal=0
    trap 'deferred_signal=129' HUP
    trap 'deferred_signal=130' INT
    trap 'deferred_signal=143' TERM
}

end_deferred_signals() {
    local signal
    restore_signal_traps
    signal=$deferred_signal
    deferred_signal=0
    ((signal == 0)) || exit "$signal"
}

stop_monitors() {
    local pid

    for pid in "${monitor_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${monitor_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    monitor_pids=()
}

start_monitors() {
    local name=$1

    cp /proc/softirqs "$log_dir/host-softirqs-$name-before.txt"
    begin_deferred_signals
    pidstat -t -u -r -w -p "$target_pid,$qemu_pid" 1 >"$log_dir/host-pidstat-$name.log" &
    monitor_pids+=("$!")
    mpstat -P ALL 1 >"$log_dir/host-mpstat-$name.log" &
    monitor_pids+=("$!")
    iostat -dx -y 1 >"$log_dir/host-iostat-$name.log" &
    monitor_pids+=("$!")
    end_deferred_signals
}

cleanup() {
    local result=$?
    local deadline
    trap - EXIT HUP INT TERM
    set +e

    stop_monitors
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
        perf_pid=""
    fi
    if [[ -n $qemu_pid ]] && process_running "$qemu_pid"; then
        if [[ $guest_ready == true ]]; then
            ssh "${ssh_options[@]}" zettide@127.0.0.1 sudo poweroff >/dev/null 2>&1 || true
            deadline=$((SECONDS + 30))
            while process_running "$qemu_pid" && ((SECONDS < deadline)); do
                sleep 0.5
            done
        fi
        if process_running "$qemu_pid" && ! stop_process QEMU "$qemu_pid"; then
            result=1
        else
            wait "$qemu_pid" 2>/dev/null || true
        fi
    fi
    if [[ -n $target_pid ]] && process_running "$target_pid"; then
        if ! stop_process target "$target_pid"; then
            result=1
        fi
    elif [[ -n $target_pid ]]; then
        wait "$target_pid" 2>/dev/null || true
    fi
    if [[ $benchmark_completed == true && $benchmark_mode == pool ]]; then
        if ! grep -Eq 'provider_worker_metrics .*queue_full_rejects=0([[:space:]]|$)' "$log_dir/target.log" ||
            grep -Eq 'provider_worker_metrics .*queue_full_rejects=[1-9][0-9]*([[:space:]]|$)' "$log_dir/target.log"; then
            echo "target reported missing or nonzero queue-full metrics" >&2
            result=1
        fi
    fi
    for socket_path in "${socket_paths[@]}"; do
        if [[ -e $socket_path ]]; then
            echo "vhost socket remains after target shutdown: $socket_path" >&2
            result=1
        fi
    done
    if [[ -n $work_dir ]] && ! rm -rf -- "$work_dir"; then
        echo "failed to remove work directory: $work_dir" >&2
        result=1
    fi
    if [[ -n $socket_dir ]] && ! rm -rf -- "$socket_dir"; then
        echo "failed to remove socket directory: $socket_dir" >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
restore_signal_traps

mkdir -p "$log_dir"
work_dir=$(mktemp -d "$log_dir/vhost-fio.XXXXXX")
socket_dir=$(mktemp -d /tmp/zettide-vhost.XXXXXX)
for ((index = 0; index < controller_count; index++)); do
    socket_paths+=("$socket_dir/zettide-scheduled-pool-data-$index")
done
overlay=$work_dir/guest.qcow2
seed=$work_dir/seed.img
ssh_key=$work_dir/id_ed25519
known_hosts=$work_dir/known_hosts
user_data=$work_dir/user-data
meta_data=$work_dir/meta-data

ssh-keygen -q -t ed25519 -N "" -f "$ssh_key"
public_key=$(<"$ssh_key.pub")
[[ $public_key != *$'\n'* && $public_key != *$'\r'* ]] || {
    echo "generated SSH public key is not one line" >&2
    exit 1
}
cat >"$user_data" <<EOF
#cloud-config
write_files:
  - path: /etc/yum.repos.d/zettide-benchmark.repo
    permissions: '0644'
    content: |
      [zettide-fedora]
      name=Fedora 44 - Alibaba Cloud
      baseurl=https://mirrors.aliyun.com/fedora/releases/44/Everything/x86_64/os/
      enabled=1
      gpgcheck=1
      repo_gpgcheck=0
      gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-x86_64

      [zettide-updates]
      name=Fedora 44 Updates - Alibaba Cloud
      baseurl=https://mirrors.aliyun.com/fedora/updates/44/Everything/x86_64/
      enabled=1
      gpgcheck=1
      repo_gpgcheck=0
      gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-x86_64
users:
  - name: zettide
    groups: [wheel]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $public_key
runcmd:
  - [sh, -c, "dnf config-manager setopt fedora.enabled=0 updates.enabled=0 && dnf install -y fio jq pciutils && install -o zettide -g zettide -m 0644 /dev/null /home/zettide/.zettide-fio-ready"]
EOF
cat >"$meta_data" <<'EOF'
instance-id: zettide-vhost-fio
local-hostname: zettide-vhost-fio
EOF
cloud-localds "$seed" "$user_data" "$meta_data"
base_format=$(qemu-img info --output=json "$base_image" | jq -er '.format')
qemu-img create -q -f qcow2 -F "$base_format" -b "$base_image" "$overlay"

ssh_options=(
    -i "$ssh_key"
    -p "$ssh_port"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$known_hosts"
    -o LogLevel=ERROR
)
scp_options=(
    -i "$ssh_key"
    -P "$ssh_port"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$known_hosts"
    -o LogLevel=ERROR
)

rm -f "$ready_file"
target_command=("$target" "$ready_file" "$pool_id" "$read_policy" "${devices[@]}")
if [[ $target_gdb == 1 ]]; then
    target_command=(gdb --batch --return-child-result -ex run -ex "thread apply all bt full" --args "${target_command[@]}")
fi
if [[ $storage_transport == spdk_nvme_pcie ]]; then
    command -v prlimit >/dev/null || { echo "prlimit is required for SPDK NVMe PCIe" >&2; exit 2; }
    target_command=(prlimit --memlock=unlimited:unlimited -- "${target_command[@]}")
fi
begin_deferred_signals
target_member_windows=${ZETTIDE_POOL_DATA_MEMBER_WINDOWS:-}
[[ $benchmark_mode == pool ]] || target_member_windows=""
env ZETTIDE_POOL_DATA_FRONTEND=vhost \
    ZETTIDE_POOL_DATA_BENCHMARK_MODE="$benchmark_mode" \
    ZETTIDE_POOL_DATA_MEMBER_WINDOWS="$target_member_windows" \
    ZETTIDE_VHOST_SOCKET_DIR="$socket_dir" \
    ZETTIDE_VHOST_CONTROLLER_COUNT="$controller_count" \
    ZETTIDE_NVMF_REACTOR_COUNT="$reactor_count" \
    "${target_command[@]}" \
    >"$log_dir/target.log" 2>&1 &
target_pid=$!
end_deferred_signals
for ((attempt = 0; attempt < 1000; attempt++)); do
    sockets_ready=true
    for socket_path in "${socket_paths[@]}"; do
        [[ -S $socket_path ]] || sockets_ready=false
    done
    [[ -f $ready_file && $sockets_ready == true ]] && break
    if ! process_running "$target_pid"; then
        wait "$target_pid" || true
        echo "vhost target exited before becoming ready; see $log_dir/target.log" >&2
        exit 1
    fi
    sleep 0.01
done
for socket_path in "${socket_paths[@]}"; do
    [[ -f $ready_file && -S $socket_path ]] || {
        echo "vhost target did not create the expected socket after 10 seconds: $socket_path" >&2
        exit 1
    }
done

qemu_vhost_args=()
for ((index = 0; index < controller_count; index++)); do
    qemu_vhost_args+=(
        -chardev "socket,id=vhost-char-$index,path=${socket_paths[index]}"
        -device "vhost-user-blk-pci,chardev=vhost-char-$index,num-queues=$queues_per_controller,queue-size=256"
    )
done

qemu_memory_backend=(
    -object "memory-backend-memfd,id=mem,size=4G,share=on"
)
if [[ $storage_transport == spdk_nvme_pcie ]]; then
    hugepage_path=/dev/hugepages
    [[ $(findmnt -n -o FSTYPE --target "$hugepage_path") == hugetlbfs ]] || {
        echo "$hugepage_path must be a hugetlbfs mount for SPDK NVMe PCIe" >&2
        exit 1
    }
    hugepage_size_kib=0
    hugepage_free=0
    while read -r key value _; do
        case $key in
            Hugepagesize:) hugepage_size_kib=$value ;;
            HugePages_Free:) hugepage_free=$value ;;
        esac
    done </proc/meminfo
    if ((hugepage_size_kib * hugepage_free < 4 * 1024 * 1024)); then
        echo "at least 4 GiB of free hugepages is required for SPDK NVMe PCIe guest memory" >&2
        exit 1
    fi
    qemu_memory_backend=(
        -object "memory-backend-file,id=mem,size=4G,mem-path=$hugepage_path,share=on,prealloc=on"
    )
fi

begin_deferred_signals
"$qemu_command" \
    -name zettide-vhost-fio,debug-threads=on \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "$guest_vcpus" \
    -m 4G \
    "${qemu_memory_backend[@]}" \
    -numa node,memdev=mem \
    -drive file="$overlay",if=none,id=boot-disk,format=qcow2,cache=none \
    -device virtio-blk-pci,drive=boot-disk,bootindex=1 \
    -drive file="$seed",if=none,id=seed,format=raw,readonly=on \
    -device virtio-scsi-pci,id=seed-scsi \
    -device scsi-cd,drive=seed \
    "${qemu_vhost_args[@]}" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$ssh_port"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -nographic \
    -no-reboot \
    >"$log_dir/qemu-serial.log" 2>&1 &
qemu_pid=$!
end_deferred_signals
if [[ -n $vcpu_cpu_base ]]; then
    : >"$log_dir/qemu-vcpu-affinity.txt"
    for ((index = 0; index < guest_vcpus; index++)); do
        vcpu_tid=""
        for ((attempt = 0; attempt < 1000; attempt++)); do
            for task_path in /proc/$qemu_pid/task/*; do
                read -r task_name <"$task_path/comm" || continue
                if [[ $task_name == "CPU $index/KVM" ]]; then
                    vcpu_tid=${task_path##*/}
                    break 2
                fi
            done
            process_running "$qemu_pid" || break
            sleep 0.01
        done
        [[ -n $vcpu_tid ]] || {
            echo "failed to find QEMU vCPU thread $index" >&2
            exit 1
        }
        host_cpu=$((vcpu_cpu_base + index))
        taskset --cpu-list --pid "$host_cpu" "$vcpu_tid" >>"$log_dir/qemu-vcpu-affinity.txt"
    done
fi

deadline=$((SECONDS + 180))
while ((SECONDS < deadline)); do
    process_running "$qemu_pid" || {
        wait "$qemu_pid" || true
        echo "QEMU exited before the guest became ready; see $log_dir/qemu-serial.log" >&2
        exit 1
    }
    if ssh "${ssh_options[@]}" zettide@127.0.0.1 \
        'test -f ~/.zettide-fio-ready && command -v fio >/dev/null' 2>/dev/null; then
        guest_ready=true
        break
    fi
    sleep 1
done
[[ $guest_ready == true ]] || {
    echo "guest did not install fio and become ready after 180 seconds" >&2
    exit 1
}

cat >"$work_dir/guest-identify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected_count=$1
root_source=$(findmnt -n -o SOURCE /)
root_source=${root_source%%\[*}
mapfile -t root_disks < <(lsblk --inverse -n -r -o KNAME,TYPE "$root_source" |
    while read -r name type; do
        [[ $type == disk ]] && printf '%s\n' "$name"
    done)
[[ ${#root_disks[@]} -ge 1 ]] || {
    echo "failed to identify the root disk from $root_source" >&2
    exit 1
}
mapfile -t data_disks < <(lsblk -dn -r -o KNAME,TYPE | while read -r name type; do
    [[ $type == disk ]] || continue
    [[ $name != zram* ]] || continue
    is_root=false
    for root_disk in "${root_disks[@]}"; do
        [[ $name == "$root_disk" ]] && is_root=true
    done
    [[ $is_root == false ]] && printf '%s\n' "$name"
done)
[[ ${#data_disks[@]} -eq $expected_count ]] || {
    echo "expected $expected_count non-root whole disks, found ${#data_disks[@]}: ${data_disks[*]-}" >&2
    exit 1
}
devices=()
for data_disk in "${data_disks[@]}"; do
    device=/dev/$data_disk
    [[ $(blockdev --getro "$device") == 1 ]] || {
        echo "vhost data disk is not read-only: $device" >&2
        exit 1
    }
    devices+=("$device")
done
(IFS=:; printf '%s\n' "${devices[*]}")
EOF
chmod 0755 "$work_dir/guest-identify.sh"
scp "${scp_options[@]}" "$work_dir/guest-identify.sh" zettide@127.0.0.1:/tmp/guest-identify.sh
guest_device=$(ssh "${ssh_options[@]}" zettide@127.0.0.1 sudo /tmp/guest-identify.sh "$controller_count")
IFS=: read -r -a guest_devices <<<"$guest_device"
[[ ${#guest_devices[@]} -eq $controller_count ]] || {
    echo "guest device list does not match the controller count: $guest_device" >&2
    exit 1
}

ssh "${ssh_options[@]}" zettide@127.0.0.1 'lsblk -o NAME,KNAME,TYPE,SIZE,RO,MODEL,SERIAL' >"$log_dir/guest-lsblk.txt"
ssh "${ssh_options[@]}" zettide@127.0.0.1 'lspci -nn' >"$log_dir/guest-lspci.txt"
ssh "${ssh_options[@]}" zettide@127.0.0.1 'uname -a' >"$log_dir/guest-uname.txt"
ssh "${ssh_options[@]}" zettide@127.0.0.1 'fio --version' >"$log_dir/guest-fio-version.txt"

run_case() {
    local name=$1
    local rw=$2
    local block_size=$3
    local depth=$4
    local jobs=$5
    local size=$6
    local job_file=$work_dir/fio.job
    cat >"$job_file" <<EOF
[global]
filename=$guest_device
rw=$rw
bs=$block_size
size=$size
offset_increment=$size
ioengine=io_uring
iodepth=$depth
numjobs=$jobs
direct=1
invalidate=1
group_reporting=1
time_based=1
runtime=$runtime
ramp_time=$ramp_time
randrepeat=0
norandommap=1
percentile_list=50:95:99:99.9

[$name]
EOF
    execute_case "$name" "$job_file"
}

run_raw_nvme_case() {
    local name=randread-4k-qd256-j1-per-device
    local job_file=$work_dir/fio.job
    local index

    cat >"$job_file" <<EOF
[global]
rw=randread
bs=4k
size=$fio_size
ioengine=io_uring
iodepth=256
direct=1
invalidate=1
time_based=1
runtime=$runtime
ramp_time=$ramp_time
randrepeat=0
norandommap=1
percentile_list=50:95:99:99.9
EOF
    for index in "${!guest_devices[@]}"; do
        cat >>"$job_file" <<EOF

[$name-device-$index]
filename=${guest_devices[index]}
EOF
    done
    execute_case "$name" "$job_file"
}

execute_case() {
    local name=$1
    local job_file=$2
    local result=$log_dir/fio-$name.json
    local status

    scp "${scp_options[@]}" "$job_file" zettide@127.0.0.1:/tmp/zettide-fio.job
    start_monitors "$name"
    if [[ -n $perf_case && $name == "$perf_case" ]]; then
        perf_data=$log_dir/perf-$name.data
        begin_deferred_signals
        perf record --quiet --freq "$perf_frequency" --call-graph fp \
            --pid "$target_pid,$qemu_pid" --output "$perf_data" &
        perf_pid=$!
        end_deferred_signals
    fi
    set +e
    if [[ $benchmark_mode == raw_nvme ]]; then
        ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'sudo fio --readonly --eta=never --output-format=json+ /tmp/zettide-fio.job'
    else
        ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'sudo fio --readonly --eta=never --output-format=json /tmp/zettide-fio.job'
    fi >"$result"
    status=$?
    set -e
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
        perf_pid=""
        perf report --stdio --no-children --call-graph none --percent-limit 0.1 \
            --sort=comm,dso,symbol --input "$perf_data" >"$log_dir/perf-$name-self.txt"
        perf report --stdio --percent-limit 0.1 \
            --sort=comm,dso,symbol --input "$perf_data" >"$log_dir/perf-$name-inclusive.txt"
    fi
    stop_monitors
    cp /proc/softirqs "$log_dir/host-softirqs-$name-after.txt"
    ((status == 0)) || return "$status"
    jq -e '.jobs | length > 0 and all(.error == 0)' "$result" >/dev/null
    if [[ $benchmark_mode == raw_nvme ]]; then
        jq -r --arg name "$name" '
            [.jobs[] | select(.error == 0)] as $jobs |
            ($jobs | map(.read.total_ios) | add) as $total_ios |
            [
                $jobs[].read.clat_ns.bins | to_entries[] |
                {latency_ns: (.key | tonumber), count: .value}
            ] |
            group_by(.latency_ns) |
            map({latency_ns: .[0].latency_ns, count: (map(.count) | add)}) as $bins |
            ($bins | map(.count) | add) as $binned_ios |
            if $total_ios <= 0 or $binned_ios != $total_ios then
                error("invalid aggregate latency histogram")
            else
                ($total_ios * 99 / 100 | ceil) as $p99_rank |
                (reduce $bins[] as $bin (
                    {count: 0, p99_ns: null};
                    .count += $bin.count |
                    if .p99_ns == null and .count >= $p99_rank then
                        .p99_ns = $bin.latency_ns
                    else
                        .
                    end
                )) as $percentile |
                $name + " iops=" + (($jobs | map(.read.iops) | add) | tostring) +
                " bw_bytes=" + (($jobs | map(.read.bw_bytes) | add) | tostring) +
                " mean_ns=" + ((($jobs | map(.read.clat_ns.mean * .read.total_ios) | add) / $total_ios) | tostring) +
                " p99_ns=" + ($percentile.p99_ns | tostring)
            end' "$result"
    else
        jq -r '(.jobs[0].jobname) + " iops=" + (.jobs[0].read.iops|tostring) +
            " bw_bytes=" + (.jobs[0].read.bw_bytes|tostring) +
            " mean_ns=" + (.jobs[0].read.clat_ns.mean|tostring) +
            " p99_ns=" + (.jobs[0].read.clat_ns.percentile["99.000000"]|tostring)' "$result"
    fi
}

run_selected_case() {
    [[ -z $fio_case || $fio_case == "$1" ]] || return 0
    run_case "$@"
}

run_selected_case seq-read-1m-qd32-j1 read 1m 32 1 "$fio_size"
run_selected_case seq-read-128k-qd1-j1 read 128k 1 1 "$fio_size"
run_selected_case randread-4k-qd1-j1 randread 4k 1 1 "$fio_size"
run_selected_case randread-4k-qd32-j1 randread 4k 32 1 "$fio_size"
run_selected_case randread-4k-qd32-j4 randread 4k 32 4 "$fio_size"
run_selected_case randread-4k-qd32-j16 randread 4k 32 16 "$fio_size"
[[ $fio_case != randread-4k-qd256-j1-per-device ]] || run_raw_nvme_case
benchmark_completed=true
