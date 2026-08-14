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
base_image=${ZETTIDE_VHOST_BASE_IMAGE:?ZETTIDE_VHOST_BASE_IMAGE is required}
socket_name=zettide-scheduled-pool-data-0
target_pid=""
qemu_pid=""
guest_ready=false
benchmark_completed=false
work_dir=""
socket_dir=""
socket_path=""
monitor_pids=()

case $fio_case in
    "" | seq-read-1m-qd32-j1 | seq-read-128k-qd1-j1 | randread-4k-qd1-j1 | randread-4k-qd32-j1 | randread-4k-qd32-j4 | randread-4k-qd32-j16) ;;
    *)
        echo "unknown vhost-user-blk fio case: $fio_case" >&2
        exit 2
        ;;
esac

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
((queues <= guest_vcpus)) || {
    echo "vhost queue count must not exceed guest vCPU count" >&2
    exit 2
}

qemu_command=""
if command -v qemu-system-x86_64 >/dev/null; then
    qemu_command=$(command -v qemu-system-x86_64)
elif command -v qemu-kvm >/dev/null; then
    qemu_command=$(command -v qemu-kvm)
else
    echo "qemu-system-x86_64 or qemu-kvm is required" >&2
    exit 2
fi
for command_name in qemu-img cloud-localds ssh scp ssh-keygen jq pidstat mpstat iostat; do
    command -v "$command_name" >/dev/null || {
        echo "$command_name is required" >&2
        exit 2
    }
done

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
    pidstat -t -u -r -w -p "$target_pid,$qemu_pid" 1 >"$log_dir/host-pidstat-$name.log" &
    monitor_pids+=("$!")
    mpstat -P ALL 1 >"$log_dir/host-mpstat-$name.log" &
    monitor_pids+=("$!")
    iostat -dx -y 1 >"$log_dir/host-iostat-$name.log" &
    monitor_pids+=("$!")
}

cleanup() {
    local result=$?
    local deadline
    trap - EXIT INT TERM
    set +e

    stop_monitors
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
    if [[ $benchmark_completed == true ]]; then
        if ! grep -Eq 'provider_worker_metrics .*queue_full_rejects=0([[:space:]]|$)' "$log_dir/target.log" ||
            grep -Eq 'provider_worker_metrics .*queue_full_rejects=[1-9][0-9]*([[:space:]]|$)' "$log_dir/target.log"; then
            echo "target reported missing or nonzero queue-full metrics" >&2
            result=1
        fi
    fi
    if [[ -n $socket_path && -e $socket_path ]]; then
        echo "vhost socket remains after target shutdown: $socket_path" >&2
        result=1
    fi
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
trap 'exit 130' INT TERM

mkdir -p "$log_dir"
work_dir=$(mktemp -d "$log_dir/vhost-fio.XXXXXX")
socket_dir=$(mktemp -d /tmp/zettide-vhost.XXXXXX)
socket_path=$socket_dir/$socket_name
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
env ZETTIDE_POOL_DATA_FRONTEND=vhost \
    ZETTIDE_VHOST_SOCKET_DIR="$socket_dir" \
    ZETTIDE_NVMF_REACTOR_COUNT="$reactor_count" \
    "$target" "$ready_file" "$pool_id" "$read_policy" "${devices[@]}" \
    >"$log_dir/target.log" 2>&1 &
target_pid=$!
for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -f $ready_file && -S $socket_path ]] && break
    if ! process_running "$target_pid"; then
        wait "$target_pid" || true
        echo "vhost target exited before becoming ready; see $log_dir/target.log" >&2
        exit 1
    fi
    sleep 0.01
done
[[ -f $ready_file && -S $socket_path ]] || {
    echo "vhost target did not create the expected socket after 10 seconds: $socket_path" >&2
    exit 1
}

"$qemu_command" \
    -name zettide-vhost-fio \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "$guest_vcpus" \
    -m 4G \
    -object memory-backend-memfd,id=mem,size=4G,share=on \
    -numa node,memdev=mem \
    -drive file="$overlay",if=virtio,format=qcow2,cache=none \
    -drive file="$seed",if=none,id=seed,format=raw,readonly=on \
    -device virtio-scsi-pci,id=seed-scsi \
    -device scsi-cd,drive=seed \
    -chardev socket,id=vhost-char,path="$socket_path" \
    -device vhost-user-blk-pci,chardev=vhost-char,num-queues="$queues",queue-size=256 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$ssh_port"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -nographic \
    -no-reboot \
    >"$log_dir/qemu-serial.log" 2>&1 &
qemu_pid=$!

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
[[ ${#data_disks[@]} -eq 1 ]] || {
    echo "expected exactly one non-root whole disk, found ${#data_disks[@]}: ${data_disks[*]-}" >&2
    exit 1
}
device=/dev/${data_disks[0]}
[[ $(blockdev --getro "$device") == 1 ]] || {
    echo "vhost data disk is not read-only: $device" >&2
    exit 1
}
printf '%s\n' "$device"
EOF
chmod 0755 "$work_dir/guest-identify.sh"
scp "${scp_options[@]}" "$work_dir/guest-identify.sh" zettide@127.0.0.1:/tmp/guest-identify.sh
guest_device=$(ssh "${ssh_options[@]}" zettide@127.0.0.1 sudo /tmp/guest-identify.sh)

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
    local result=$log_dir/fio-$name.json
    local status

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
    scp "${scp_options[@]}" "$job_file" zettide@127.0.0.1:/tmp/zettide-fio.job
    start_monitors "$name"
    set +e
    ssh "${ssh_options[@]}" zettide@127.0.0.1 \
        'sudo fio --readonly --eta=never --output-format=json /tmp/zettide-fio.job' >"$result"
    status=$?
    set -e
    stop_monitors
    cp /proc/softirqs "$log_dir/host-softirqs-$name-after.txt"
    ((status == 0)) || return "$status"
    jq -e '.jobs | length > 0 and all(.error == 0)' "$result" >/dev/null
    jq -r '(.jobs[0].jobname) + " iops=" + (.jobs[0].read.iops|tostring) +
        " bw_bytes=" + (.jobs[0].read.bw_bytes|tostring) +
        " mean_ns=" + (.jobs[0].read.clat_ns.mean|tostring) +
        " p99_ns=" + (.jobs[0].read.clat_ns.percentile["99.000000"]|tostring)' "$result"
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
benchmark_completed=true
