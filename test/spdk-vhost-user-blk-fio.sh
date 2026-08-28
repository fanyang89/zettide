#!/usr/bin/env bash
set -euo pipefail

storage_transport=${ZETTIDE_POOL_DATA_STORAGE_TRANSPORT:-linux}
if [[ $storage_transport == synthetic ]]; then
    [[ $# -eq 4 ]] || {
        echo "usage: spdk-vhost-user-blk-fio.sh TARGET READY_FILE LOG_DIR READ_POLICY" >&2
        exit 2
    }
    target=$1
    ready_file=$2
    log_dir=$3
    pool_id=""
    read_policy=$4
    devices=()
else
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
fi

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
cpu_profile_case=${ZETTIDE_VHOST_CPU_PROFILE_CASE:-}
cpu_profile_signal=12
vcpu_cpu_base=${ZETTIDE_VHOST_VCPU_CPU_BASE:-}
target_cpu_list=${ZETTIDE_VHOST_TARGET_CPU_LIST:-}
guest_mitigations_off=${ZETTIDE_VHOST_GUEST_MITIGATIONS_OFF:-0}
target_gdb=${ZETTIDE_VHOST_TARGET_GDB:-0}
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
fio_pid=""
fio_ready_file=/tmp/zettide-fio-ramp-ready
perf_data=""
cpu_profile_active=false
cpu_profile_path=""
deferred_signal=0

case $fio_case in
    "" | seq-read-1m-qd32-j1 | seq-read-128k-qd1-j1 | randread-4k-qd1-j1 | randread-4k-qd32-j1 | randread-4k-qd32-j4 | randread-4k-qd16-j32 | randread-4k-qd32-j16 | randread-4k-qd32-j32 | randread-4k-qd256-j1-per-device) ;;
    *)
        echo "unknown vhost-user-blk fio case: $fio_case" >&2
        exit 2
        ;;
esac
[[ $benchmark_mode == pool || $benchmark_mode == raw_nvme ]] || {
    echo "benchmark mode must be pool or raw_nvme" >&2
    exit 2
}
[[ $storage_transport == linux || $storage_transport == spdk_nvme_pcie || $storage_transport == synthetic ]] || {
    echo "storage transport must be linux, spdk_nvme_pcie, or synthetic" >&2
    exit 2
}
if [[ $storage_transport == synthetic && $benchmark_mode != pool ]]; then
    echo "synthetic storage requires Pool benchmark mode" >&2
    exit 2
fi
if [[ $benchmark_mode == raw_nvme ]]; then
    [[ $storage_transport == spdk_nvme_pcie && $controller_count -eq 2 &&
        ($fio_case == randread-4k-qd32-j16 ||
            $fio_case == randread-4k-qd256-j1-per-device) ]] || {
        echo "raw NVMe mode requires SPDK PCIe, two controllers, and a supported random-read case" >&2
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
((runtime <= 86400)) || { echo "fio runtime exceeds 86400 seconds: $runtime" >&2; exit 2; }
((ramp_time <= 3600)) || { echo "fio ramp time exceeds 3600 seconds: $ramp_time" >&2; exit 2; }
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
if [[ -n $cpu_profile_case && $cpu_profile_case != "$fio_case" ]]; then
    echo "CPU profile case must match the selected fio case" >&2
    exit 2
fi
if [[ -n $cpu_profile_case && -n $perf_case ]]; then
    echo "CPU profiling and perf recording must run separately" >&2
    exit 2
fi
if [[ -n $cpu_profile_case && $target_gdb == 1 ]]; then
    echo "CPU profiling and target debugging must run separately" >&2
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
if [[ -n $cpu_profile_case ]]; then
    command -v nm >/dev/null || {
        echo "nm is required when a CPU profile case is selected" >&2
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

    begin_deferred_signals
    pidstat -t -u -r -w -p "$target_pid,$qemu_pid" 1 >"$log_dir/host-pidstat-$name.log" &
    monitor_pids+=("$!")
    mpstat -P ALL 1 >"$log_dir/host-mpstat-$name.log" &
    monitor_pids+=("$!")
    iostat -dx -y 1 >"$log_dir/host-iostat-$name.log" &
    monitor_pids+=("$!")
    end_deferred_signals
}

record_pid_threads() {
    local role=$1 pid=$2 task_path tid comm status_line allowed voluntary nonvoluntary
    local stat_line stat_fields processor
    local -a fields=()

    [[ -d /proc/$pid/task ]] || return 0
    for task_path in "/proc/$pid/task"/*; do
        tid=${task_path##*/}
        IFS= read -r comm <"$task_path/comm" 2>/dev/null || continue
        allowed=unknown
        voluntary=unknown
        nonvoluntary=unknown
        [[ -r $task_path/status ]] || continue
        while IFS= read -r status_line; do
            case $status_line in
                Cpus_allowed_list:*) allowed=${status_line#*:} ;;
                voluntary_ctxt_switches:*) voluntary=${status_line#*:} ;;
                nonvoluntary_ctxt_switches:*) nonvoluntary=${status_line#*:} ;;
            esac
        done <"$task_path/status" 2>/dev/null || continue
        allowed=${allowed//$'\t'/}
        voluntary=${voluntary//$'\t'/}
        nonvoluntary=${nonvoluntary//$'\t'/}
        IFS= read -r stat_line <"$task_path/stat" 2>/dev/null || continue
        stat_fields=${stat_line##*) }
        read -r -a fields <<<"$stat_fields"
        processor=${fields[36]:-unknown}
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$role" "$pid" "$tid" "$processor" "$allowed" "$voluntary" "$nonvoluntary" "$comm"
    done
}

record_thread_snapshot() {
    local name=$1
    {
        printf 'role\tpid\ttid\tprocessor\tallowed_cpus\tvoluntary_switches\tnonvoluntary_switches\tcomm\n'
        record_pid_threads target "$target_pid"
        record_pid_threads qemu "$qemu_pid"
    } >"$log_dir/host-threads-$name.txt"
}

fio_jobs_ready() {
    local expected_jobs=$1
    ssh "${ssh_options[@]}" zettide@127.0.0.1 \
        "count=\$(wc -c < $fio_ready_file 2>/dev/null) || exit 1; test \"\$count\" -ge $expected_jobs" \
        2>/dev/null
}

first_cpu_profile_file() {
    local profile_file

    while IFS= read -r profile_file; do
        printf '%s\n' "$profile_file"
        return 0
    done < <(compgen -G "$cpu_profile_path*")
    return 1
}

stop_cpu_profile() {
    local profile_file

    [[ $cpu_profile_active == true ]] || return 0
    kill -"$cpu_profile_signal" "$target_pid" 2>/dev/null || {
        echo "failed to stop target CPU profiling" >&2
        return 1
    }
    cpu_profile_active=false
    sleep 0.2
    profile_file=$(first_cpu_profile_file || true)
    [[ -n $profile_file && -s $profile_file ]] || {
        echo "target CPU profile is missing or empty: $cpu_profile_path*" >&2
        return 1
    }
}

cleanup() {
    local result=$?
    local deadline
    trap - EXIT HUP INT TERM
    set +e

    stop_monitors
    if [[ -n $fio_pid ]]; then
        kill -TERM "$fio_pid" 2>/dev/null || true
        wait "$fio_pid" 2>/dev/null || true
        fio_pid=""
    fi
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
        perf_pid=""
    fi
    if ! stop_cpu_profile; then
        result=1
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
        if [[ $storage_transport == synthetic ]] &&
            { ! grep -Eq 'pool_read_path_metrics .*async_submitted=[1-9][0-9]* async_fallbacks=0 async_submit_errors=0([[:space:]]|$)' "$log_dir/target.log" ||
                ! grep -Eq 'pool_async_metrics submissions=[1-9][0-9]* completions=[1-9][0-9]* queue_full=0([[:space:]]|$)' "$log_dir/target.log"; }; then
            echo "synthetic storage reported missing, fallback, or queue-full async reads" >&2
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
if [[ -n $cpu_profile_case ]]; then
    if ! nm -g --defined-only "$target" | grep -E ' [TW] ProfilerStart$' >/dev/null; then
        echo "target does not contain the gperftools CPU profiler: $target" >&2
        exit 2
    fi
    cpu_profile_path=$log_dir/gperftools-$cpu_profile_case.prof
    rm -f "$cpu_profile_path" "$cpu_profile_path".*
    cp "$target" "$log_dir/gperftools-target"
fi
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
if [[ $storage_transport == synthetic ]]; then
    target_command=("$target" "$ready_file" "$read_policy")
else
    target_command=("$target" "$ready_file" "$pool_id" "$read_policy" "${devices[@]}")
fi
if [[ $target_gdb == 1 ]]; then
    target_command=(gdb --batch --return-child-result -ex run -ex "thread apply all bt full" --args "${target_command[@]}")
fi
if [[ $storage_transport == spdk_nvme_pcie ]]; then
    command -v prlimit >/dev/null || { echo "prlimit is required for SPDK NVMe PCIe" >&2; exit 2; }
    target_command=(prlimit --memlock=unlimited:unlimited -- "${target_command[@]}")
fi
if [[ -n $target_cpu_list ]]; then
    command -v taskset >/dev/null || { echo "taskset is required for target CPU pinning" >&2; exit 2; }
    target_command=(taskset -c "$target_cpu_list" "${target_command[@]}")
fi
begin_deferred_signals
target_member_windows=${ZETTIDE_POOL_DATA_MEMBER_WINDOWS:-}
[[ $benchmark_mode == pool ]] || target_member_windows=""
target_environment=(
    env
    ZETTIDE_POOL_DATA_FRONTEND=vhost
    ZETTIDE_POOL_DATA_BENCHMARK_MODE="$benchmark_mode"
    ZETTIDE_POOL_DATA_STORAGE_TRANSPORT="$storage_transport"
    ZETTIDE_POOL_DATA_MEMBER_WINDOWS="$target_member_windows"
    ZETTIDE_VHOST_SOCKET_DIR="$socket_dir"
    ZETTIDE_VHOST_CONTROLLER_COUNT="$controller_count"
    ZETTIDE_NVMF_REACTOR_COUNT="$reactor_count"
)
if [[ -n $cpu_profile_case ]]; then
    target_environment+=(CPUPROFILE="$cpu_profile_path" CPUPROFILESIGNAL="$cpu_profile_signal")
fi
"${target_environment[@]}" "${target_command[@]}" \
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
qemu_reboot_args=(-no-reboot)
if [[ $guest_mitigations_off == 1 ]]; then
    # The guest reboots once to apply mitigations=off; poweroff still terminates
    # QEMU because -no-shutdown is not set.
    qemu_reboot_args=()
fi
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
    "${qemu_reboot_args[@]}" \
    >"$log_dir/qemu-serial.log" 2>&1 &
qemu_pid=$!
end_deferred_signals
if [[ -n $vcpu_cpu_base ]]; then
    : >"$log_dir/qemu-vcpu-affinity.txt"
    for ((index = 0; index < guest_vcpus; index++)); do
        vcpu_tid=""
        for ((attempt = 0; attempt < 1000; attempt++)); do
            for task_path in "/proc/$qemu_pid/task"/*; do
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

if [[ $guest_mitigations_off == 1 ]]; then
    ssh "${ssh_options[@]}" zettide@127.0.0.1 \
        'sudo grubby --update-kernel=ALL --args="mitigations=off" && sudo reboot' >/dev/null 2>&1 || true
    sleep 5
    guest_ready=false
    deadline=$((SECONDS + 180))
    while ((SECONDS < deadline)); do
        process_running "$qemu_pid" || {
            wait "$qemu_pid" || true
            echo "QEMU exited during the mitigations=off reboot; see $log_dir/qemu-serial.log" >&2
            exit 1
        }
        if ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'test -f ~/.zettide-fio-ready && command -v fio >/dev/null' 2>/dev/null; then
            guest_ready=true
            break
        fi
        sleep 2
    done
    [[ $guest_ready == true ]] || {
        echo "guest did not come back after the mitigations=off reboot" >&2
        exit 1
    }
fi

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
ssh "${ssh_options[@]}" zettide@127.0.0.1 'cat /proc/cmdline' >"$log_dir/guest-cmdline.txt"
ssh "${ssh_options[@]}" zettide@127.0.0.1 'lscpu; lscpu -e=CPU,NODE,SOCKET,CORE,CACHE,ONLINE' \
    >"$log_dir/guest-cpu-topology.txt"
ssh "${ssh_options[@]}" zettide@127.0.0.1 '
    for path in /sys/devices/system/cpu/vulnerabilities/*; do
        test -r "$path" || continue
        printf "%s: " "${path##*/}"
        cat "$path"
    done
' >"$log_dir/guest-vulnerabilities.txt"
ssh "${ssh_options[@]}" zettide@127.0.0.1 '
    for pair in \
        isolated_cpus:/sys/devices/system/cpu/isolated \
        nohz_full:/sys/devices/system/cpu/nohz_full \
        nmi_watchdog:/proc/sys/kernel/nmi_watchdog \
        numa_balancing:/proc/sys/kernel/numa_balancing; do
        label=${pair%%:*}
        path=${pair#*:}
        test -r "$path" || continue
        value=$(cat "$path")
        printf "%s=%s\n" "$label" "$value"
    done
    if command -v systemctl >/dev/null; then
        printf "irqbalance_active="
        systemctl is-active irqbalance || true
        printf "irqbalance_enabled="
        systemctl is-enabled irqbalance || true
    fi
' >"$log_dir/guest-scheduling.txt"
record_thread_snapshot initial

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
exec_prerun=/bin/sh -c 'printf x >> $fio_ready_file'
randrepeat=0
norandommap=1
percentile_list=50:95:99:99.9

[$name]
EOF
    execute_case "$name" "$job_file" "$jobs"
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
exec_prerun=/bin/sh -c 'printf x >> $fio_ready_file'
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
    execute_case "$name" "$job_file" "${#guest_devices[@]}"
}

normalize_fio_json_output() {
    local result=$1
    local preamble=${result%.json}-preamble.log
    local clean=$result.clean
    local line
    local json_started=false

    : >"$preamble"
    : >"$clean"
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $json_started == false ]]; then
            if [[ $line == \{ ]]; then
                json_started=true
            else
                printf '%s\n' "$line" >>"$preamble"
                continue
            fi
        fi
        printf '%s\n' "$line" >>"$clean"
    done <"$result"
    if [[ $json_started == false ]]; then
        rm -f "$clean"
        echo "fio output did not contain JSON: $result" >&2
        return 1
    fi
    mv "$clean" "$result"
}

execute_case() {
    local name=$1
    local job_file=$2
    local expected_jobs=$3
    local result=$log_dir/fio-$name.json
    local status
    local deadline
    local measurement_started=false
    local attempt

    scp "${scp_options[@]}" "$job_file" zettide@127.0.0.1:/tmp/zettide-fio.job
    ssh "${ssh_options[@]}" zettide@127.0.0.1 "sudo rm -f $fio_ready_file"
    start_monitors "$name"
    if [[ -n $perf_case && $name == "$perf_case" ]]; then
        perf_data=$log_dir/perf-$name.data
        begin_deferred_signals
        perf record --quiet --freq "$perf_frequency" --call-graph fp \
            --pid "$target_pid,$qemu_pid" --output "$perf_data" &
        perf_pid=$!
        end_deferred_signals
    fi
    if [[ -n $cpu_profile_case && $name == "$cpu_profile_case" ]]; then
        kill -"$cpu_profile_signal" "$target_pid"
        cpu_profile_active=true
        deadline=$((SECONDS + 2))
        while ! first_cpu_profile_file >/dev/null; do
            process_running "$target_pid" || {
                echo "target exited while starting CPU profiling" >&2
                return 1
            }
            ((SECONDS < deadline)) || {
                echo "target did not start CPU profiling" >&2
                return 1
            }
            sleep 0.01
        done
    fi
    set +e
    if [[ $benchmark_mode == raw_nvme ]]; then
        ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'sudo fio --readonly --eta=never --output-format=json+ /tmp/zettide-fio.job' >"$result" &
    else
        ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'sudo fio --readonly --eta=never --output-format=json /tmp/zettide-fio.job' >"$result" &
    fi
    fio_pid=$!
    set -e
    for ((attempt = 0; attempt < 300; attempt++)); do
        process_running "$fio_pid" || break
        fio_jobs_ready "$expected_jobs" && break
        sleep 0.1
    done
    if process_running "$fio_pid" && fio_jobs_ready "$expected_jobs"; then
        for ((attempt = 0; attempt < ramp_time * 10; attempt++)); do
            process_running "$fio_pid" || break
            sleep 0.1
        done
        if process_running "$fio_pid"; then
            cp /proc/interrupts "$log_dir/host-interrupts-$name-before.txt"
            cp /proc/softirqs "$log_dir/host-softirqs-$name-before.txt"
            ssh "${ssh_options[@]}" zettide@127.0.0.1 \
                'cat /proc/interrupts' >"$log_dir/guest-interrupts-$name-before.txt"
            ssh "${ssh_options[@]}" zettide@127.0.0.1 \
                'cat /proc/softirqs' >"$log_dir/guest-softirqs-$name-before.txt"
            record_thread_snapshot "$name-before"
            measurement_started=true
        fi
    elif process_running "$fio_pid"; then
        echo "fio did not report ramp start after 30 seconds" >&2
        kill -TERM "$fio_pid" 2>/dev/null || true
    fi
    set +e
    wait "$fio_pid"
    status=$?
    fio_pid=""
    set -e
    if [[ $measurement_started == true ]]; then
        cp /proc/interrupts "$log_dir/host-interrupts-$name-after.txt"
        cp /proc/softirqs "$log_dir/host-softirqs-$name-after.txt"
        ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'cat /proc/interrupts' >"$log_dir/guest-interrupts-$name-after.txt"
        ssh "${ssh_options[@]}" zettide@127.0.0.1 \
            'cat /proc/softirqs' >"$log_dir/guest-softirqs-$name-after.txt"
        record_thread_snapshot "$name-after"
    elif ((status == 0)); then
        echo "fio completed before the measured phase started" >&2
        status=1
    fi
    stop_cpu_profile
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
    ((status == 0)) || return "$status"
    normalize_fio_json_output "$result"
    jq -e '.jobs | length > 0 and all(.error == 0)' "$result" >/dev/null
    if [[ $benchmark_mode == raw_nvme ]]; then
        jq -r --arg name "$name" '
            [.jobs[] | select(.error == 0)] as $jobs |
            ($jobs | map(.read.clat_ns.N) | add) as $sample_count |
            [
                $jobs[].read.clat_ns.bins | to_entries[] |
                {latency_ns: (.key | tonumber), count: .value}
            ] |
            group_by(.latency_ns) |
            map({latency_ns: .[0].latency_ns, count: (map(.count) | add)}) as $bins |
            ($bins | map(.count) | add) as $binned_samples |
            if $sample_count <= 0 or $binned_samples != $sample_count then
                error("invalid aggregate latency histogram")
            else
                ($sample_count * 99 / 100 | ceil) as $p99_rank |
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
                " mean_ns=" + ((($jobs | map(.read.clat_ns.mean * .read.clat_ns.N) | add) / $sample_count) | tostring) +
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
run_selected_case randread-4k-qd16-j32 randread 4k 16 32 "$fio_size"
run_selected_case randread-4k-qd32-j16 randread 4k 32 16 "$fio_size"
run_selected_case randread-4k-qd32-j32 randread 4k 32 32 "$fio_size"
[[ $fio_case != randread-4k-qd256-j1-per-device ]] || run_raw_nvme_case
benchmark_completed=true
