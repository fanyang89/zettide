#!/usr/bin/env bash
# Nameref output parameters are consumed by their callers.
# shellcheck disable=SC2034
set -euo pipefail
export LC_ALL=C

storage_transport=${ZETTIDE_POOL_DATA_STORAGE_TRANSPORT:-linux}
if [[ $storage_transport == synthetic ]]; then
    [[ $# -eq 1 ]] || {
        echo "usage: scheduled-pool-nvmf-fio.sh CLI" >&2
        exit 2
    }
    cli=$1
    physical_devices=()
    expected_serials=()
else
    [[ $# -eq 3 || $# -eq 5 ]] || {
        echo "usage: scheduled-pool-nvmf-fio.sh CLI DEVICE SERIAL [DEVICE SERIAL]" >&2
        exit 2
    }
    cli=$1
    physical_devices=("$2")
    expected_serials=("$3")
    if [[ $# -eq 5 ]]; then
        physical_devices+=("$4")
        expected_serials+=("$5")
    fi
fi
physical_device_count=${#physical_devices[@]}
member_count=$((physical_device_count * 3))
confirmation=${ZETTIDE_SCHEDULED_POOL_NVMF_FIO_CONFIRM:-}
target=${ZETTIDE_SCHEDULED_POOL_NVMF_TARGET:?ZETTIDE_SCHEDULED_POOL_NVMF_TARGET is required}
read_policy=${ZETTIDE_SCHEDULED_POOL_NVMF_READ_POLICY:-first_available}
expected_pool_id=${ZETTIDE_SCHEDULED_POOL_NVMF_EXPECTED_POOL_ID:-}
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
benchmark_driver=${ZETTIDE_SCHEDULED_POOL_BENCHMARK_DRIVER:-test/spdk-nvmf-fio.sh}
benchmark_log_name=${ZETTIDE_SCHEDULED_POOL_BENCHMARK_LOG_NAME:-nvmf}
lifecycle_profile=${ZETTIDE_SCHEDULED_POOL_PROFILE:-nvmf-scheduled-pool-rxe-fio}
raw_windows=${ZETTIDE_SCHEDULED_POOL_RAW_WINDOWS:-0}
pcie_namespace_text=${ZETTIDE_POOL_DATA_PCIE_NAMESPACES:-}
pcie_preparation_mode=${ZETTIDE_POOL_DATA_PCIE_PREPARATION_MODE:-create}
benchmark_mode=${ZETTIDE_POOL_DATA_BENCHMARK_MODE:-pool}
canonical_devices=()
physical_ids=()
frozen_serials=()
capacities=()
loops=()
loop_backings=()
loop_offsets=()
loop_sizes=()
loop_ids=()
member_physical_indexes=()
member_slice_indexes=()
slice_size=0
pool_id=""
loops_detached=true
test_succeeded=false
deferred_signal=0
pcie_namespaces=()
pcie_bdfs=()
pcie_original_drivers=()
pcie_restore_needed=()
benchmark_pid=""

contains_forbidden_identity_character() {
    [[ $1 =~ :|[[:cntrl:]] ]]
}

[[ $EUID -eq 0 ]] || { echo "scheduled Pool NVMe-oF fio requires root" >&2; exit 2; }
[[ $read_policy == first_available || $read_policy == quorum ]] || {
    echo "read policy must be first_available or quorum" >&2
    exit 2
}
[[ $raw_windows == 0 || $raw_windows == 1 ]] || {
    echo "raw window mode must be 0 or 1" >&2
    exit 2
}
[[ $storage_transport == linux || $storage_transport == spdk_nvme_pcie || $storage_transport == synthetic ]] || {
    echo "storage transport must be linux, spdk_nvme_pcie, or synthetic" >&2
    exit 2
}
[[ $benchmark_mode == pool || $benchmark_mode == raw_nvme ]] || {
    echo "benchmark mode must be pool or raw_nvme" >&2
    exit 2
}
if [[ $storage_transport == synthetic ]]; then
    [[ $benchmark_mode == pool && $raw_windows == 0 && -z $expected_pool_id &&
        $benchmark_driver == test/spdk-vhost-user-blk-fio.sh ]] || {
        echo "synthetic storage requires Pool vhost mode without devices or Pool metadata" >&2
        exit 2
    }
    [[ -x $target ]] || { echo "target is unavailable" >&2; exit 2; }
    if [[ $benchmark_driver != test/* || $benchmark_driver == *..* || ! -x $benchmark_driver ]]; then
        echo "benchmark driver must be an executable repository-relative test/ path without .." >&2
        exit 2
    fi
    [[ $benchmark_log_name =~ ^[a-z0-9-]+$ ]] || {
        echo "benchmark log name must contain only lowercase letters, digits, and hyphens" >&2
        exit 2
    }
    mkdir -p "$log_dir"
    unset ZETTIDE_POOL_DATA_MEMBER_WINDOWS
    export ZETTIDE_POOL_DATA_STORAGE_TRANSPORT=$storage_transport
    exec bash "$benchmark_driver" "$target" "$log_dir/$benchmark_log_name-ready" \
        "$log_dir/$benchmark_log_name" "$read_policy"
fi
if [[ $storage_transport == spdk_nvme_pcie ]]; then
    [[ $physical_device_count -eq 2 && $raw_windows == 1 ]] || {
        echo "SPDK NVMe PCIe requires two physical devices and raw windows" >&2
        exit 2
    }
    IFS=, read -r -a pcie_namespaces <<<"$pcie_namespace_text"
    [[ ${#pcie_namespaces[@]} -eq 2 ]] || {
        echo "SPDK NVMe PCIe requires exactly two BDF/NSID values" >&2
        exit 2
    }
    for namespace in "${pcie_namespaces[@]}"; do
        [[ $namespace =~ ^([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])/1$ ]] || {
            echo "PCIe namespace must use canonical BDF/1 syntax: $namespace" >&2
            exit 2
        }
        pcie_bdfs+=("${BASH_REMATCH[1]}")
        pcie_restore_needed+=(0)
    done
    [[ ${pcie_bdfs[0]} != "${pcie_bdfs[1]}" ]] || {
        echo "PCIe controller BDFs must be distinct" >&2
        exit 2
    }
    [[ $pcie_preparation_mode == create || $pcie_preparation_mode == validate ]] || {
        echo "SPDK NVMe PCIe preparation mode must be create or validate" >&2
        exit 2
    }
    if [[ $pcie_preparation_mode == validate && ! $expected_pool_id =~ ^[0-9a-f]{32}$ ]]; then
        echo "SPDK NVMe PCIe validation requires an expected Pool ID" >&2
        exit 2
    fi
fi
if [[ $benchmark_mode == raw_nvme ]] &&
    [[ $storage_transport != spdk_nvme_pcie || $pcie_preparation_mode != validate ||
        ! $expected_pool_id =~ ^[0-9a-f]{32}$ || $benchmark_driver != test/spdk-vhost-user-blk-fio.sh ]]; then
    echo "raw NVMe vhost requires SPDK PCIe, validation-only Pool preparation, an expected Pool ID, and the vhost benchmark driver" >&2
    exit 2
fi
for command in blkdiscard blockdev date fuser grep jq losetup lsblk mkdir mktemp readlink sleep tr udevadm umount wipefs; do
    command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }
done
[[ -x $cli && -x $target ]] || {
    echo "CLI or target is unavailable" >&2
    exit 2
}
if [[ $benchmark_driver != test/* || $benchmark_driver == *..* || ! -x $benchmark_driver ]]; then
    echo "benchmark driver must be an executable repository-relative test/ path without .." >&2
    exit 2
fi
if [[ ! $benchmark_log_name =~ ^[a-z0-9-]+$ ]]; then
    echo "benchmark log name must contain only lowercase letters, digits, and hyphens" >&2
    exit 2
fi
for physical_index in "${!physical_devices[@]}"; do
    if [[ -z ${physical_devices[$physical_index]} || -z ${expected_serials[$physical_index]} ]] ||
        contains_forbidden_identity_character "${physical_devices[$physical_index]}" ||
        contains_forbidden_identity_character "${expected_serials[$physical_index]}"; then
        echo "device paths and serials must be non-empty and contain no colon or ASCII control character" >&2
        exit 2
    fi
done
if ((physical_device_count == 2)) && [[ ${expected_serials[0]} == "${expected_serials[1]}" ]]; then
    echo "physical device serials must be distinct" >&2
    exit 2
fi

if [[ $storage_transport == spdk_nvme_pcie ]]; then
    expected_confirmation="DESTROY:spdk_nvme_pcie:${physical_devices[0]}:${expected_serials[0]}:${pcie_namespaces[0]}:${physical_devices[1]}:${expected_serials[1]}:${pcie_namespaces[1]}"
else
    expected_confirmation="DESTROY:${physical_devices[0]}:${expected_serials[0]}"
    if ((physical_device_count == 2)); then
        expected_confirmation+=":${physical_devices[1]}:${expected_serials[1]}"
    fi
fi
[[ $confirmation == "$expected_confirmation" ]] || {
    echo "scheduled Pool destructive confirmation mismatch" >&2
    exit 2
}

mkdir -p "$log_dir"
events_log=$log_dir/lifecycle-events.log
: >"$events_log"
: >"$log_dir/device-holders.log"

record_event() {
    printf '%s %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$events_log"
}

next_enumeration_file() {
    local kind=$1
    mktemp "$log_dir/.${kind}.XXXXXX"
}

freeze_identity() {
    local physical_index=$1 configured expected_serial canonical identity_json physical_id actual_serial
    configured=${physical_devices[$physical_index]}
    expected_serial=${expected_serials[$physical_index]}
    if [[ -n ${canonical_devices[$physical_index]+set} || -n ${physical_ids[$physical_index]+set} ||
        -n ${frozen_serials[$physical_index]+set} ]]; then
        echo "physical device identity was already frozen: $physical_index" >&2
        return 1
    fi
    [[ -b $configured ]] || {
        echo "block device is unavailable: $configured" >&2
        return 1
    }
    if ! canonical=$(readlink -f -- "$configured") || [[ -z $canonical || ! -b $canonical ]]; then
        echo "failed to canonicalize block device: $configured" >&2
        return 1
    fi
    if ! identity_json=$(lsblk --nodeps --json --paths --output PATH,TYPE,SERIAL,MAJ:MIN "$canonical"); then
        echo "failed to read whole-disk identity: $configured" >&2
        return 1
    fi
    if ! jq --exit-status --arg path "$canonical" --arg serial "$expected_serial" '
        .blockdevices as $devices |
        ($devices | length) == 1 and
        $devices[0].path == $path and
        $devices[0].type == "disk" and
        ($devices[0].serial | type) == "string" and
        ($devices[0].serial | length) > 0 and
        $devices[0].serial == $serial and
        ($devices[0]["maj:min"] | type) == "string" and
        ($devices[0]["maj:min"] | test("^[0-9]+:[0-9]+$"))
    ' <<<"$identity_json" >/dev/null; then
        echo "whole-disk identity mismatch: $configured" >&2
        return 1
    fi
    if ! physical_id=$(jq --exit-status --raw-output '.blockdevices[0]["maj:min"]' <<<"$identity_json"); then
        echo "failed to read whole-disk MAJ:MIN: $configured" >&2
        return 1
    fi
    if ! actual_serial=$(jq --exit-status --raw-output '.blockdevices[0].serial | select(type == "string" and length > 0)' <<<"$identity_json"); then
        echo "failed to read whole-disk serial: $configured" >&2
        return 1
    fi
    canonical_devices[physical_index]=$canonical
    physical_ids[physical_index]=$physical_id
    frozen_serials[physical_index]=$actual_serial
}

check_frozen_identity() {
    local physical_index=$1 canonical expected_serial expected_id identity_json resolved
    canonical=${canonical_devices[$physical_index]-}
    expected_serial=${frozen_serials[$physical_index]-}
    expected_id=${physical_ids[$physical_index]-}
    [[ -n $canonical && -n $expected_serial && -n $expected_id && -b $canonical ]] || {
        echo "frozen device identity is unavailable for physical device $physical_index" >&2
        return 1
    }
    if ! resolved=$(readlink -f -- "$canonical") || [[ $resolved != "$canonical" ]]; then
        echo "frozen canonical device changed: $canonical" >&2
        return 1
    fi
    if ! identity_json=$(lsblk --nodeps --json --paths --output PATH,TYPE,SERIAL,MAJ:MIN "$canonical"); then
        echo "failed to re-read frozen device identity: $canonical" >&2
        return 1
    fi
    if ! jq --exit-status --arg path "$canonical" --arg serial "$expected_serial" --arg id "$expected_id" '
        .blockdevices as $devices |
        ($devices | length) == 1 and
        $devices[0].path == $path and
        $devices[0].type == "disk" and
        ($devices[0].serial | type) == "string" and
        ($devices[0].serial | length) > 0 and
        $devices[0].serial == $serial and
        $devices[0]["maj:min"] == $id
    ' <<<"$identity_json" >/dev/null; then
        echo "frozen whole-disk identity changed: $canonical" >&2
        return 1
    fi
}

check_all_frozen_identities() {
    local physical_index
    for physical_index in "${!physical_devices[@]}"; do
        check_frozen_identity "$physical_index"
    done
}

validate_pcie_devices() {
    local physical_index bdf pci_path block_path group_path group_device group_bdf
    local hugepages_free hugepage_size nsid namespace_count controller_path namespace_path driver_override
    local block_class_path
    [[ $storage_transport == spdk_nvme_pcie ]] || return 0
    hugepages_free=$(awk '/^HugePages_Free:/ { print $2 }' /proc/meminfo)
    hugepage_size=$(awk '/^Hugepagesize:/ { print $2 }' /proc/meminfo)
    [[ $hugepage_size == 2048 && $hugepages_free =~ ^[0-9]+$ && $hugepages_free -ge 256 ]] || {
        echo "SPDK NVMe PCIe requires at least 256 free 2 MiB hugepages" >&2
        return 1
    }
    for physical_index in "${!pcie_bdfs[@]}"; do
        bdf=${pcie_bdfs[$physical_index]}
        pci_path=$(readlink -f -- "/sys/bus/pci/devices/$bdf") || return 1
        block_class_path=/sys/class/block/$(basename "${canonical_devices[$physical_index]}")
        block_path=$(readlink -f -- "$block_class_path/device") || return 1
        [[ $block_path == "$pci_path"/* ]] || {
            echo "block device does not belong directly to configured PCIe controller (native NVMe multipath heads are unsupported): ${canonical_devices[$physical_index]} $bdf" >&2
            return 1
        }
        nsid=$(<"$block_class_path/nsid") || return 1
        [[ $nsid == 1 ]] || {
            echo "configured block device is not namespace ID 1: ${canonical_devices[$physical_index]} nsid=$nsid" >&2
            return 1
        }
        namespace_count=0
        for controller_path in "$pci_path"/nvme/nvme*; do
            [[ -d $controller_path ]] || continue
            for namespace_path in "$controller_path"/nvme*n*; do
                [[ -d $namespace_path ]] || continue
                namespace_count=$((namespace_count + 1))
                [[ $(basename "$namespace_path") == "$(basename "${canonical_devices[$physical_index]}")" ]] || {
                    echo "PCIe controller exposes an additional namespace: $bdf $(basename "$namespace_path")" >&2
                    return 1
                }
            done
        done
        [[ $namespace_count -eq 1 ]] || {
            echo "PCIe controller must expose exactly one namespace: $bdf" >&2
            return 1
        }
        [[ -L $pci_path/iommu_group ]] || {
            echo "PCIe controller has no IOMMU group: $bdf" >&2
            return 1
        }
        group_path=$(readlink -f -- "$pci_path/iommu_group") || return 1
        [[ -d $group_path/devices ]] || {
            echo "PCIe controller has an invalid IOMMU group: $bdf" >&2
            return 1
        }
        for group_device in "$group_path"/devices/*; do
            group_bdf=$(basename "$group_device")
            [[ $group_bdf == "$bdf" ]] || {
                echo "IOMMU group contains an unapproved device: $bdf group=$(basename "$group_path") member=$group_bdf" >&2
                return 1
            }
        done
        [[ -L $pci_path/driver ]] || {
            echo "PCIe controller has no bound driver: $bdf" >&2
            return 1
        }
        pcie_original_drivers[physical_index]=$(basename "$(readlink -f -- "$pci_path/driver")")
        [[ ${pcie_original_drivers[$physical_index]} == nvme ]] || {
            echo "PCIe controller must initially use the nvme driver: $bdf" >&2
            return 1
        }
        driver_override=$(<"$pci_path/driver_override") || return 1
        [[ $driver_override == "(null)" ]] || {
            echo "PCIe controller must not have a driver override: $bdf override=$driver_override" >&2
            return 1
        }
    done
}

bind_pcie_devices() {
    local physical_index bdf pci_path
    [[ $storage_transport == spdk_nvme_pcie ]] || return 0
    validate_pcie_devices
    modprobe vfio-pci
    for physical_index in "${!pcie_bdfs[@]}"; do
        bdf=${pcie_bdfs[$physical_index]}
        pci_path=/sys/bus/pci/devices/$bdf
        pcie_restore_needed[physical_index]=1
        printf '%s\n' vfio-pci >"$pci_path/driver_override"
        printf '%s' "$bdf" >"$pci_path/driver/unbind"
        printf '%s' "$bdf" >/sys/bus/pci/drivers_probe
        [[ $(basename "$(readlink -f -- "$pci_path/driver")") == vfio-pci ]] || {
            echo "failed to bind PCIe controller to vfio-pci: $bdf" >&2
            return 1
        }
        record_event "vfio-bound physical_index=$physical_index bdf=$bdf"
    done
}

refresh_pcie_identity() {
    local physical_index=$1 bdf=${pcie_bdfs[$1]} expected_serial=${frozen_serials[$1]}
    local identity_json canonical physical_id pci_path block_path
    identity_json=$(lsblk --nodeps --json --paths --output PATH,TYPE,SERIAL,MAJ:MIN)
    canonical=$(jq --exit-status --raw-output --arg serial "$expected_serial" '
        [.blockdevices[] | select(.type == "disk" and .serial == $serial)] |
        select(length == 1) | .[0].path
    ' <<<"$identity_json") || return 1
    physical_id=$(jq --exit-status --raw-output --arg path "$canonical" '
        .blockdevices[] | select(.path == $path) | .["maj:min"]
    ' <<<"$identity_json") || return 1
    pci_path=$(readlink -f -- "/sys/bus/pci/devices/$bdf") || return 1
    block_path=$(readlink -f -- "/sys/class/block/$(basename "$canonical")/device") || return 1
    [[ $block_path == "$pci_path"/* ]] || return 1
    canonical_devices[physical_index]=$canonical
    physical_ids[physical_index]=$physical_id
}

restore_pcie_devices() {
    local physical_index bdf pci_path current_driver original_driver driver_override status=0
    [[ $storage_transport == spdk_nvme_pcie ]] || return 0
    for ((physical_index=${#pcie_bdfs[@]} - 1; physical_index >= 0; physical_index--)); do
        [[ ${pcie_restore_needed[$physical_index]:-0} == 1 ]] || continue
        bdf=${pcie_bdfs[$physical_index]}
        pci_path=/sys/bus/pci/devices/$bdf
        original_driver=${pcie_original_drivers[$physical_index]}
        current_driver=""
        [[ -L $pci_path/driver ]] && current_driver=$(basename "$(readlink -f -- "$pci_path/driver")")
        if [[ $current_driver != "$original_driver" ]]; then
            printf '%s\n' "$original_driver" >"$pci_path/driver_override" || status=1
            if [[ -n $current_driver ]]; then
                printf '%s' "$bdf" >"/sys/bus/pci/drivers/$current_driver/unbind" || status=1
            fi
            printf '%s' "$bdf" >/sys/bus/pci/drivers_probe || status=1
        fi
        printf '\n' >"$pci_path/driver_override" || status=1
        driver_override=$(<"$pci_path/driver_override") || {
            driver_override=unreadable
            status=1
        }
        if [[ -L $pci_path/driver &&
            $(basename "$(readlink -f -- "$pci_path/driver")") == "$original_driver" &&
            $driver_override == "(null)" ]]; then
            pcie_restore_needed[physical_index]=0
            record_event "vfio-restored physical_index=$physical_index bdf=$bdf driver=$original_driver"
        else
            status=1
            record_event "vfio-restore-incomplete physical_index=$physical_index bdf=$bdf"
        fi
    done
    udevadm settle --timeout=10 || status=1
    for physical_index in "${!pcie_bdfs[@]}"; do
        refresh_pcie_identity "$physical_index" || status=1
    done
    return "$status"
}

prepare_pcie_pool() {
    local result_path=$log_dir/spdk-pcie-pool-id expected_id=00000000000000000000000000000000 prepare_status=0
    local -a prepared_ids=()
    [[ ! -e $result_path ]]
    if [[ $pcie_preparation_mode == validate ]]; then
        expected_id=$expected_pool_id
    fi
    begin_attach_deferred_signals
    env -u ZETTIDE_POOL_DATA_PCIE_PROBE \
        ZETTIDE_POOL_DATA_BENCHMARK_MODE=pool \
        ZETTIDE_POOL_DATA_STORAGE_TRANSPORT=spdk_nvme_pcie \
        ZETTIDE_POOL_DATA_PREPARATION_MODE="$pcie_preparation_mode" \
        ZETTIDE_POOL_DATA_MEMBER_WINDOWS="$raw_window_specs" \
        prlimit --memlock=unlimited:unlimited -- \
        "$target" "$result_path" "$expected_id" "$read_policy" \
        "${pcie_namespaces[@]}" >"$log_dir/spdk-pcie-prepare.log" 2>&1 &
    benchmark_pid=$!
    end_attach_deferred_signals
    wait "$benchmark_pid" || prepare_status=$?
    benchmark_pid=""
    if ((prepare_status != 0)); then
        echo "SPDK NVMe PCIe Pool preparation failed; inspect $log_dir/spdk-pcie-prepare.log" >&2
        return 1
    fi
    mapfile -t prepared_ids <"$result_path"
    if ((${#prepared_ids[@]} != 1)) || [[ ! ${prepared_ids[0]} =~ ^[0-9a-f]{32}$ ]]; then
        echo "SPDK NVMe PCIe Pool preparation returned an invalid Pool ID" >&2
        return 1
    fi
    pool_id=${prepared_ids[0]}
    if [[ $pcie_preparation_mode == validate && $pool_id != "$expected_pool_id" ]]; then
        echo "SPDK NVMe PCIe Pool ID does not match the expected identity" >&2
        return 1
    fi
    record_event "spdk-pcie-pool-prepared mode=$pcie_preparation_mode pool=$pool_id namespaces=$pcie_namespace_text"
}

enumerate_device_tree() {
    local physical_index=$1 paths_name=$2 mounts_name=$3 canonical json_file paths_file mounts_file
    local -n paths_ref=$paths_name
    local -n mounts_ref=$mounts_name
    canonical=${canonical_devices[$physical_index]-}
    if ! json_file=$(next_enumeration_file device-tree.json) ||
        ! paths_file=$(next_enumeration_file device-paths.bin) ||
        ! mounts_file=$(next_enumeration_file device-mounts.bin); then
        echo "failed to allocate device-tree enumeration files" >&2
        return 1
    fi
    if ! lsblk --json --paths --output PATH,MOUNTPOINTS "$canonical" >"$json_file"; then
        echo "failed to enumerate device tree: $canonical" >&2
        return 1
    fi
    if ! jq --exit-status --arg root "$canonical" '
        [.blockdevices[] | recurse(.children[]?)] as $nodes |
        ($nodes | length) > 0 and
        $nodes[0].path == $root and
        all($nodes[]; (.path | type) == "string" and (.path | length) > 0) and
        all($nodes[].mountpoints[]?; . == null or (type == "string"))
    ' "$json_file" >/dev/null; then
        echo "invalid device-tree enumeration: $canonical" >&2
        return 1
    fi
    if ! jq --join-output --raw-output '
        .blockdevices[] | recurse(.children[]?) | .path + "\u0000"
    ' "$json_file" >"$paths_file"; then
        echo "failed to enumerate descendant paths: $canonical" >&2
        return 1
    fi
    if ! jq --join-output --raw-output '
        .blockdevices[] | recurse(.children[]?) | .mountpoints[]? |
        select(. != null and . != "") | . + "\u0000"
    ' "$json_file" >"$mounts_file"; then
        echo "failed to enumerate descendant mounts: $canonical" >&2
        return 1
    fi
    paths_ref=()
    mounts_ref=()
    if ! mapfile -d '' -t paths_ref <"$paths_file" || ! mapfile -d '' -t mounts_ref <"$mounts_file"; then
        echo "failed to load device-tree enumeration: $canonical" >&2
        return 1
    fi
    ((${#paths_ref[@]} > 0)) || {
        echo "device-tree enumeration is empty: $canonical" >&2
        return 1
    }
}

enumerate_associated_loops() {
    local backing=$1 result_name=$2 output stderr_file
    local -n result_ref=$result_name
    if ! stderr_file=$(next_enumeration_file losetup.stderr); then
        echo "failed to allocate loop enumeration file" >&2
        return 1
    fi
    if ! output=$(losetup --associated "$backing" --noheadings --raw --output NAME 2>"$stderr_file"); then
        echo "failed to enumerate loops associated with $backing" >&2
        return 1
    fi
    if [[ -s $stderr_file ]]; then
        echo "losetup reported a diagnostic while enumerating $backing" >&2
        return 1
    fi
    result_ref=()
    if [[ -n $output ]]; then
        if ! mapfile -t result_ref <<<"$output"; then
            echo "failed to load loop enumeration for $backing" >&2
            return 1
        fi
    fi
}

unmount_descendants() {
    local physical_index=$1 canonical mountpoint quoted_mountpoint longest_index candidate_index
    local -a paths=() mountpoints=()
    canonical=${canonical_devices[$physical_index]}
    enumerate_device_tree "$physical_index" paths mountpoints || return 1
    while ((${#mountpoints[@]} > 0)); do
        longest_index=0
        for candidate_index in "${!mountpoints[@]}"; do
            if ((${#mountpoints[$candidate_index]} > ${#mountpoints[$longest_index]})); then
                longest_index=$candidate_index
            fi
        done
        mountpoint=${mountpoints[$longest_index]}
        printf -v quoted_mountpoint '%q' "$mountpoint"
        record_event "unmount-started physical_device=$canonical mountpoint=$quoted_mountpoint"
        if ! umount -- "$mountpoint"; then
            record_event "unmount-failed physical_device=$canonical mountpoint=$quoted_mountpoint"
            echo "failed to unmount descendant of $canonical: $mountpoint" >&2
            return 1
        fi
        record_event "unmount-succeeded physical_device=$canonical mountpoint=$quoted_mountpoint"
        unset 'mountpoints[longest_index]'
        mountpoints=("${mountpoints[@]}")
    done
    enumerate_device_tree "$physical_index" paths mountpoints || return 1
    if ((${#mountpoints[@]} != 0)); then
        record_event "unmount-verification-failed physical_device=$canonical remaining=${#mountpoints[@]}"
        echo "device still has mounted descendants: $canonical" >&2
        return 1
    fi
}

check_fuser_idle() {
    local path=$1 stderr_file fuser_rc=0 diagnostic
    if ! stderr_file=$(next_enumeration_file fuser.stderr); then
        echo "failed to allocate fuser diagnostic file" >&2
        return 1
    fi
    if fuser "$path" >>"$log_dir/device-holders.log" 2>"$stderr_file"; then
        fuser_rc=0
    else
        fuser_rc=$?
    fi
    diagnostic=false
    if [[ -s $stderr_file ]]; then
        diagnostic=true
        while IFS= read -r line || [[ -n $line ]]; do
            printf '%s\n' "$line" >>"$log_dir/device-holders.log"
        done <"$stderr_file"
    fi
    if ((fuser_rc == 0)); then
        echo "device is used by another process: $path" >&2
        return 1
    fi
    if ((fuser_rc != 1)) || [[ $diagnostic == true ]]; then
        echo "fuser could not prove device idle: $path (rc=$fuser_rc)" >&2
        return 1
    fi
}

require_idle_device() {
    local physical_index=$1 root path canonical_path kernel_name holder_dir holder
    local -a paths=() mountpoints=() associated=()
    root=${canonical_devices[$physical_index]}
    enumerate_device_tree "$physical_index" paths mountpoints || return 1
    ((${#mountpoints[@]} == 0)) || {
        echo "device has mounted descendants: $root" >&2
        return 1
    }
    for path in "${paths[@]}"; do
        if ! canonical_path=$(readlink -f -- "$path") || [[ -z $canonical_path || ! -b $canonical_path ]]; then
            echo "failed to canonicalize device-tree member: $path" >&2
            return 1
        fi
        enumerate_associated_loops "$canonical_path" associated || return 1
        ((${#associated[@]} == 0)) || {
            echo "device-tree member has associated loops: $canonical_path: ${associated[*]}" >&2
            return 1
        }
        check_fuser_idle "$canonical_path" || return 1
        if ! kernel_name=$(lsblk --nodeps --noheadings --output KNAME "$canonical_path") ||
            [[ -z $kernel_name || $kernel_name == *[[:space:]]* ]]; then
            echo "failed to resolve kernel block name: $canonical_path" >&2
            return 1
        fi
        holder_dir=/sys/class/block/$kernel_name/holders
        if [[ ! -d $holder_dir || ! -r $holder_dir || ! -x $holder_dir ]]; then
            echo "kernel holder directory is unavailable: $canonical_path" >&2
            return 1
        fi
        for holder in "$holder_dir"/*; do
            [[ -e $holder ]] || continue
            echo "device has kernel holders: $canonical_path" >&2
            return 1
        done
    done
}

require_all_idle() {
    local physical_index
    for physical_index in "${!physical_devices[@]}"; do
        require_idle_device "$physical_index"
    done
}

verify_no_associated_loops() {
    local physical_index=$1 path canonical_path
    local -a paths=() mountpoints=() associated=()
    enumerate_device_tree "$physical_index" paths mountpoints || return 1
    for path in "${paths[@]}"; do
        if ! canonical_path=$(readlink -f -- "$path") || [[ -z $canonical_path || ! -b $canonical_path ]]; then
            echo "failed to canonicalize device-tree member during loop cleanup: $path" >&2
            return 1
        fi
        enumerate_associated_loops "$canonical_path" associated || return 1
        if ((${#associated[@]} != 0)); then
            echo "loop devices remain associated with $canonical_path: ${associated[*]}" >&2
            return 1
        fi
    done
}

read_loop_identity() {
    local loop=$1 backing_name=$2 offset_name=$3 limit_name=$4 id_name=$5
    local read_backing read_offset read_limit read_id canonical_backing
    local -n backing_ref=$backing_name offset_ref=$offset_name limit_ref=$limit_name id_ref=$id_name
    if ! read_backing=$(losetup --noheadings --raw --output BACK-FILE "$loop") ||
        ! read_offset=$(losetup --noheadings --raw --output OFFSET "$loop") ||
        ! read_limit=$(losetup --noheadings --raw --output SIZELIMIT "$loop") ||
        ! read_id=$(lsblk --nodeps --noheadings --output MAJ:MIN "$loop" | tr -d '[:space:]'); then
        return 1
    fi
    if ! canonical_backing=$(readlink -f -- "$read_backing"); then
        return 1
    fi
    [[ -n $canonical_backing && $read_offset =~ ^[0-9]+$ && $read_limit =~ ^[0-9]+$ &&
        $read_id =~ ^[0-9]+:[0-9]+$ ]] || return 1
    backing_ref=$canonical_backing
    offset_ref=$read_offset
    limit_ref=$read_limit
    id_ref=$read_id
}

validate_loop_member() {
    local member_index=$1 loop expected_backing expected_offset expected_size expected_id
    local backing actual_offset actual_limit actual_id physical_index
    loop=${loops[$member_index]-}
    expected_backing=${loop_backings[$member_index]-}
    expected_offset=${loop_offsets[$member_index]-}
    expected_size=${loop_sizes[$member_index]-}
    expected_id=${loop_ids[$member_index]-}
    physical_index=${member_physical_indexes[$member_index]-}
    [[ -n $loop && -n $expected_backing && $expected_offset =~ ^[0-9]+$ &&
        $expected_size =~ ^[0-9]+$ && -n $expected_id && $physical_index =~ ^[0-9]+$ ]] || return 1
    read_loop_identity "$loop" backing actual_offset actual_limit actual_id || return 1
    [[ $backing == "$expected_backing" && $backing == "${canonical_devices[$physical_index]-}" ]] || return 1
    [[ $actual_offset -eq $expected_offset && $actual_limit -eq $expected_size && $actual_id == "$expected_id" ]] || return 1
    [[ $(blockdev --getsize64 "$loop") -eq $expected_size && $(blockdev --getss "$loop") -eq 4096 ]] || return 1
    [[ $(blockdev --getro "$loop") -eq 0 && -w $loop ]]
}

detach_loops() {
    local member_index loop expected_backing expected_offset expected_size expected_id
    local backing actual_offset actual_limit actual_id physical_index status=0
    for member_index in "${!loops[@]}"; do
        loop=${loops[$member_index]-}
        [[ -n $loop ]] || continue
        expected_backing=${loop_backings[$member_index]-}
        expected_offset=${loop_offsets[$member_index]-}
        expected_size=${loop_sizes[$member_index]-}
        expected_id=${loop_ids[$member_index]-}
        if [[ ! -b $loop ]]; then
            loops[member_index]=""
            loop_ids[member_index]=""
            continue
        fi
        if ! read_loop_identity "$loop" backing actual_offset actual_limit actual_id; then
            echo "failed to read loop identity: $loop" >&2
            record_event "loop-detach-refused member=$member_index loop=$loop reason=identity-unavailable"
            status=1
            continue
        fi
        if [[ -z $expected_backing || ! $expected_offset =~ ^[0-9]+$ || ! $expected_size =~ ^[0-9]+$ ||
            $backing != "$expected_backing" || $actual_offset -ne $expected_offset ||
            $actual_limit -ne $expected_size ]]; then
            echo "refusing to detach loop whose identity changed: $loop" >&2
            record_event "loop-detach-refused member=$member_index loop=$loop reason=identity-changed"
            status=1
            continue
        fi
        if [[ -z $expected_id ]]; then
            echo "refusing to detach loop without a frozen MAJ:MIN: $loop" >&2
            record_event "loop-detach-refused member=$member_index loop=$loop reason=id-unavailable"
            status=1
            continue
        fi
        if [[ $actual_id != "$expected_id" ]]; then
            echo "refusing to detach loop whose MAJ:MIN changed: $loop" >&2
            record_event "loop-detach-refused member=$member_index loop=$loop reason=id-changed"
            status=1
            continue
        fi
        if losetup --detach "$loop"; then
            loops[member_index]=""
            loop_ids[member_index]=""
            record_event "loop-detached member=$member_index loop=$loop"
        else
            status=1
        fi
    done
    udevadm settle || status=1
    for physical_index in "${!canonical_devices[@]}"; do
        if ! verify_no_associated_loops "$physical_index"; then
            record_event "loop-cleanup-incomplete physical_device=${canonical_devices[$physical_index]}"
            status=1
        fi
    done
    if ((status == 0)); then
        for member_index in "${!loops[@]}"; do
            loops[member_index]=""
            loop_ids[member_index]=""
        done
        loops_detached=true
    else
        loops_detached=false
    fi
    return "$status"
}

finish() {
    local command_rc=$? cleanup_rc=0 physical_index restore_attempt restore_rc=1
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    for restore_attempt in 1 2 3; do
        if restore_pcie_devices; then
            restore_rc=0
            break
        fi
        sleep 1
    done
    ((restore_rc == 0)) || cleanup_rc=1
    detach_loops || cleanup_rc=1
    {
        echo "profile=$lifecycle_profile"
        echo "physical_devices=$physical_device_count"
        echo "members=$member_count"
        echo "device=${physical_devices[0]}"
        echo "serial=${expected_serials[0]}"
        echo "capacity=${capacities[0]:-0}"
        for physical_index in "${!physical_devices[@]}"; do
            echo "physical_device_$physical_index=${canonical_devices[$physical_index]:-${physical_devices[$physical_index]}}"
            echo "physical_serial_$physical_index=${expected_serials[$physical_index]}"
            echo "physical_capacity_$physical_index=${capacities[$physical_index]:-0}"
        done
        echo "pool_id=$pool_id"
        echo "slice_size=$slice_size"
        echo "storage_transport=$storage_transport"
        echo "benchmark_mode=$benchmark_mode"
        echo "pcie_namespaces=$pcie_namespace_text"
        echo "loops_detached=$loops_detached"
        echo "test_succeeded=$test_succeeded"
        echo "command_rc=$command_rc"
        echo "cleanup_rc=$cleanup_rc"
    } >"$log_dir/lifecycle.log"
    record_event "cleanup physical_devices=$physical_device_count members=$member_count loops_detached=$loops_detached test_succeeded=$test_succeeded command_rc=$command_rc cleanup_rc=$cleanup_rc"
    [[ $cleanup_rc -eq 0 ]] || exit 1
    exit "$command_rc"
}

for physical_index in "${!physical_devices[@]}"; do
    freeze_identity "$physical_index"
done
if ((physical_device_count == 2)) &&
    [[ ${canonical_devices[0]} == "${canonical_devices[1]}" || ${physical_ids[0]} == "${physical_ids[1]}" ]]; then
    echo "physical devices must be distinct whole disks" >&2
    exit 2
fi
if [[ $storage_transport == spdk_nvme_pcie ]]; then
    command -v modprobe >/dev/null || { echo "modprobe is required for SPDK NVMe PCIe" >&2; exit 2; }
    command -v prlimit >/dev/null || { echo "prlimit is required for SPDK NVMe PCIe" >&2; exit 2; }
    modprobe vfio-pci
    validate_pcie_devices
fi

handle_signal() {
    local status=$1
    trap '' HUP INT TERM
    if [[ -n $benchmark_pid ]] && kill -0 "$benchmark_pid" 2>/dev/null; then
        kill -TERM "$benchmark_pid" 2>/dev/null || true
        wait "$benchmark_pid" 2>/dev/null || true
        benchmark_pid=""
    fi
    exit "$status"
}

trap finish EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

restore_signal_traps() {
    trap 'handle_signal 129' HUP
    trap 'handle_signal 130' INT
    trap 'handle_signal 143' TERM
}

defer_signal() {
    deferred_signal=$1
}

begin_attach_deferred_signals() {
    deferred_signal=0
    trap 'defer_signal 129' HUP
    trap 'defer_signal 130' INT
    trap 'defer_signal 143' TERM
}

end_attach_deferred_signals() {
    local signal
    restore_signal_traps
    signal=$deferred_signal
    deferred_signal=0
    ((signal == 0)) || handle_signal "$signal"
}

prepare_member_geometry() {
    local member_index physical_index slice_index
    if ((physical_device_count == 1)); then
        member_physical_indexes=(0 0 0)
        member_slice_indexes=(0 1 2)
    else
        member_physical_indexes=(0 1 1 0 0 1)
        member_slice_indexes=(0 0 1 1 2 2)
    fi
    loops=()
    loop_backings=()
    loop_offsets=()
    loop_sizes=()
    loop_ids=()
    for member_index in "${!member_physical_indexes[@]}"; do
        physical_index=${member_physical_indexes[$member_index]}
        slice_index=${member_slice_indexes[$member_index]}
        loops[member_index]=""
        loop_backings[member_index]=${canonical_devices[$physical_index]}
        loop_offsets[member_index]=$((slice_index * slice_size))
        loop_sizes[member_index]=$slice_size
        loop_ids[member_index]=""
    done
}

attach_slices() {
    local member_index physical_index slice_index offset loop loop_id loop_output status=0
    local backing actual_offset actual_limit actual_id
    local -a attached_counts=(0 0) loop_lines=()
    local -A seen_loop_ids=()
    prepare_member_geometry
    loops_detached=false
    begin_attach_deferred_signals
    for member_index in "${!member_physical_indexes[@]}"; do
        physical_index=${member_physical_indexes[$member_index]}
        slice_index=${member_slice_indexes[$member_index]}
        offset=${loop_offsets[$member_index]}
        if ((offset + slice_size > capacities[physical_index])); then
            status=1
            break
        fi
        if ! loop_output=$(next_enumeration_file loop-attach.stdout); then
            status=1
            break
        fi
        if ! losetup --find --show --sector-size 4096 --offset "$offset" \
            --sizelimit "$slice_size" "${canonical_devices[$physical_index]}" >"$loop_output"; then
            status=1
            break
        fi
        IFS= read -r 'loops[member_index]' <"$loop_output" || true
        loop=${loops[$member_index]-}
        loop_lines=()
        if ! mapfile -t loop_lines <"$loop_output"; then
            status=1
            break
        fi
        if ((${#loop_lines[@]} != 1)) || [[ -z $loop || ${loop_lines[0]-} != "$loop" ]]; then
            status=1
            break
        fi
        if ! read_loop_identity "$loop" backing actual_offset actual_limit actual_id; then
            status=1
            break
        fi
        loop_id=$actual_id
        loop_ids[member_index]=$loop_id
        if [[ $backing != "${loop_backings[$member_index]}" ||
            $actual_offset -ne ${loop_offsets[$member_index]} ||
            $actual_limit -ne ${loop_sizes[$member_index]} ||
            -n ${seen_loop_ids[$loop_id]+set} ]] ||
            [[ $(blockdev --getsize64 "$loop") -ne $slice_size || $(blockdev --getss "$loop") -ne 4096 ||
                $(blockdev --getro "$loop") -ne 0 || ! -w $loop ]]; then
            status=1
            break
        fi
        seen_loop_ids[$loop_id]=$loop
        attached_counts[physical_index]=$((attached_counts[physical_index] + 1))
        record_event "loop-attached member=$member_index physical_device=${canonical_devices[$physical_index]} physical_index=$physical_index slice=$slice_index loop=$loop offset=$offset size=$slice_size maj_min=$loop_id"
    done
    if [[ ${#loops[@]} -ne $member_count || ${#seen_loop_ids[@]} -ne $member_count ]]; then
        status=1
    fi
    for physical_index in "${!physical_devices[@]}"; do
        [[ ${attached_counts[$physical_index]} -eq 3 ]] || status=1
    done
    end_attach_deferred_signals
    return "$status"
}

validate_all_loop_members() {
    local member_index
    [[ ${#loops[@]} -eq $member_count ]] || return 1
    for member_index in "${!loops[@]}"; do
        validate_loop_member "$member_index" || return 1
    done
}

inspect_scheduled_pool() {
    local output=$1 member_index loop member_lines
    local -a device_args=()
    validate_all_loop_members || return 1
    check_all_frozen_identities || return 1
    for member_index in "${!loops[@]}"; do
        loop=${loops[$member_index]}
        device_args+=(--device "$loop")
    done
    [[ ${#loops[@]} -eq $member_count ]] || return 1
    "$cli" pool inspect "${device_args[@]}" >"$output" || return 1
    grep -q '^Profile: scheduled-replicated$' "$output" || return 1
    grep -q '^Data mode: blob$' "$output" || return 1
    grep -q "^Members: $member_count/$member_count$" "$output" || return 1
    grep -q '^Data policy: read_write$' "$output" || return 1
    member_lines=$(grep -c '^Member: ' "$output") || return 1
    [[ $member_lines -eq $member_count ]] || return 1
    pool_id=$(grep '^Pool: ' "$output") || return 1
    pool_id=${pool_id#Pool: }
    [[ $pool_id =~ ^[0-9a-f]{32}$ ]] || return 1
    for loop in "${loops[@]}"; do
        grep -Eq "^Member: $loop \\((authority|active-voter)\\)$" "$output" || return 1
    done
}

plan_scheduled_pool() {
    local loop label=synthetic-single-device-scheduled-nvmf
    local -a device_args=()
    if ((physical_device_count == 2)); then
        label=synthetic-dual-device-scheduled-nvmf
    fi
    for loop in "${loops[@]}"; do device_args+=(--device "$loop"); done
    validate_all_loop_members || return 1
    check_all_frozen_identities || return 1
    "$cli" pool plan-create "${device_args[@]}" --profile scheduled-replicated \
        --name-profile portable-v1 --label "$label" >"$log_dir/scheduled-plan.log" || return 1
    grep -q '^Profile: scheduled-replicated$' "$log_dir/scheduled-plan.log" || return 1
    grep -q "^Devices: $member_count$" "$log_dir/scheduled-plan.log" || return 1
    grep -q '^Data mode: blob$' "$log_dir/scheduled-plan.log" || return 1
    grep -q '^Plan: ready$' "$log_dir/scheduled-plan.log" || return 1
}

create_scheduled_pool() {
    local token loop label=synthetic-single-device-scheduled-nvmf
    local -a device_args=()
    if ((physical_device_count == 2)); then
        label=synthetic-dual-device-scheduled-nvmf
    fi
    for loop in "${loops[@]}"; do device_args+=(--device "$loop"); done
    validate_all_loop_members
    check_all_frozen_identities
    plan_scheduled_pool
    token=$(grep '^Confirm token: ' "$log_dir/scheduled-plan.log")
    token=${token#Confirm token: }
    [[ $token =~ ^[0-9a-f]{64}$ ]]
    validate_all_loop_members
    check_all_frozen_identities
    "$cli" pool create "${device_args[@]}" --profile scheduled-replicated \
        --name-profile portable-v1 --label "$label" --confirm "$token" >"$log_dir/scheduled-create.log"
    inspect_scheduled_pool "$log_dir/scheduled-inspect-created.log"
}

record_event "lifecycle-start physical_devices=$physical_device_count members=$member_count"
for physical_index in "${!physical_devices[@]}"; do
    check_frozen_identity "$physical_index"
    unmount_descendants "$physical_index"
done
check_all_frozen_identities
require_all_idle

minimum_capacity=0
for physical_index in "${!physical_devices[@]}"; do
    if ! capacity=$(blockdev --getsize64 "${canonical_devices[$physical_index]}") || [[ ! $capacity =~ ^[0-9]+$ ]]; then
        echo "failed to read device capacity: ${canonical_devices[$physical_index]}" >&2
        exit 1
    fi
    capacities[physical_index]=$capacity
    if ((minimum_capacity == 0 || capacity < minimum_capacity)); then
        minimum_capacity=$capacity
    fi
done
slice_size=$(((minimum_capacity / 3 / 1048576) * 1048576))
((slice_size >= 3 * 1024 * 1024 * 1024 && slice_size % 1048576 == 0))
for physical_index in "${!physical_devices[@]}"; do
    ((slice_size * 3 <= capacities[physical_index]))
done

prepare_member_geometry
raw_window_specs=""
for member_index in "${!member_physical_indexes[@]}"; do
    [[ -z $raw_window_specs ]] || raw_window_specs+=,
    raw_window_specs+="${member_physical_indexes[$member_index]}:${loop_offsets[$member_index]}:${loop_sizes[$member_index]}"
done

if [[ $storage_transport == spdk_nvme_pcie ]]; then
    export ZETTIDE_POOL_DATA_STORAGE_TRANSPORT=$storage_transport
    export ZETTIDE_POOL_DATA_MEMBER_WINDOWS=$raw_window_specs
    bind_pcie_devices
    prepare_pcie_pool
    benchmark_devices=("${pcie_namespaces[@]}")
    record_event "spdk-pcie-ready pool=$pool_id namespaces=$pcie_namespace_text specs=$raw_window_specs"
else
    attach_slices
validate_all_loop_members
check_all_frozen_identities
reuse_pool=false
ready_to_create=false
if ((physical_device_count == 2)); then
    if inspect_scheduled_pool "$log_dir/scheduled-inspect-reuse.log"; then
        if [[ $expected_pool_id =~ ^[0-9a-f]{32}$ && $pool_id == "$expected_pool_id" ]]; then
            reuse_pool=true
        else
            record_event "pool-reuse-refused reason=dual-device-pool-id-unconfirmed pool=$pool_id physical_devices=2 members=6"
            echo "refusing to destroy unconfirmed dual-device Pool: $pool_id" >&2
            exit 1
        fi
    else
        record_event "pool-reuse-rejected reason=dual-device-reuse-disabled-inspect-failed physical_devices=2 members=6"
    fi
    if [[ $reuse_pool == false ]] && plan_scheduled_pool; then
        ready_to_create=true
        record_event "pool-create-ready reason=devices-already-empty physical_devices=2 members=6"
    fi
elif inspect_scheduled_pool "$log_dir/scheduled-inspect-reuse.log"; then
    reuse_pool=true
fi

if [[ $reuse_pool == true ]]; then
    record_event "pool-reused pool=$pool_id profile=scheduled-replicated physical_devices=$physical_device_count members=$member_count"
elif [[ $ready_to_create == true ]]; then
    create_scheduled_pool
    record_event "pool-created pool=$pool_id profile=scheduled-replicated physical_devices=$physical_device_count members=$member_count"
else
    if ((physical_device_count == 1)); then
        record_event "pool-reuse-rejected reason=inspect-or-geometry-mismatch physical_devices=1 members=3"
    fi
    detach_loops
    check_all_frozen_identities
    require_all_idle
    for physical_index in "${!physical_devices[@]}"; do
        check_frozen_identity "$physical_index"
        require_idle_device "$physical_index"
        record_event "wipefs-started physical_device=${canonical_devices[$physical_index]}"
        wipefs --all --lock=yes "${canonical_devices[$physical_index]}"
        blockdev --rereadpt "${canonical_devices[$physical_index]}"
        record_event "wipefs-completed physical_device=${canonical_devices[$physical_index]}"
    done
    udevadm settle
    check_all_frozen_identities
    require_all_idle
    for physical_index in "${!physical_devices[@]}"; do
        check_frozen_identity "$physical_index"
        require_idle_device "$physical_index"
        record_event "blkdiscard-started physical_device=${canonical_devices[$physical_index]}"
        blkdiscard "${canonical_devices[$physical_index]}"
        blockdev --rereadpt "${canonical_devices[$physical_index]}"
        record_event "blkdiscard-completed physical_device=${canonical_devices[$physical_index]}"
    done
    udevadm settle
    check_all_frozen_identities
    require_all_idle
    attach_slices
    validate_all_loop_members
    check_all_frozen_identities
    create_scheduled_pool
    record_event "pool-created pool=$pool_id profile=scheduled-replicated physical_devices=$physical_device_count members=$member_count"
fi

validate_all_loop_members
check_all_frozen_identities
benchmark_devices=("${loops[@]}")
unset ZETTIDE_POOL_DATA_MEMBER_WINDOWS
if [[ $raw_windows == 1 ]]; then
    detach_loops
    check_all_frozen_identities
    require_all_idle
    benchmark_devices=("${canonical_devices[@]}")
    export ZETTIDE_POOL_DATA_MEMBER_WINDOWS=$raw_window_specs
    record_event "raw-window-ready physical_devices=$physical_device_count members=$member_count specs=$raw_window_specs"
fi
fi
export ZETTIDE_POOL_DATA_STORAGE_TRANSPORT=$storage_transport
begin_attach_deferred_signals
bash "$benchmark_driver" "$target" "$log_dir/$benchmark_log_name-ready" "$log_dir/$benchmark_log_name" \
    "$pool_id" "$read_policy" "${benchmark_devices[@]}" &
benchmark_pid=$!
end_attach_deferred_signals
benchmark_status=0
wait "$benchmark_pid" || benchmark_status=$?
benchmark_pid=""
((benchmark_status == 0)) || exit "$benchmark_status"
if [[ $storage_transport == spdk_nvme_pcie ]]; then
    restore_pcie_devices
    check_all_frozen_identities
fi
test_succeeded=true
record_event "benchmark-passed pool=$pool_id physical_devices=$physical_device_count members=$member_count"
