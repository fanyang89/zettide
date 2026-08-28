#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 5 ]] || {
    echo "usage: nfs-csi-kind.sh CLI GANESHA_BUILD KIND KUBECTL MANIFEST_DIR" >&2
    exit 2
}

cli=$1
ganesha_build=$2
kind=$3
kubectl=$4
manifest_dir=$5
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
nconnect=${ZETTIDE_NFS_NCONNECT:-8}
rpc_ioq_thrd_min=${ZETTIDE_NFS_RPC_IOQ_THRD_MIN:-2}
rpc_ioq_thrd_max=${ZETTIDE_NFS_RPC_IOQ_THRD_MAX:-16}
kind_node_image='kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5'
workload_image='docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f'
nfs_plugin_image='registry.k8s.io/sig-storage/nfsplugin@sha256:473611fde6406ff0b0e8ede1db680a4cfc462b72340eefcb9e80a4136ebd7bb0'
registrar_image='registry.k8s.io/sig-storage/csi-node-driver-registrar@sha256:0fc05c749072bea889beffc97499f6836f74aebe351c78ff8d90d671c35f04da'
liveness_image='registry.k8s.io/sig-storage/livenessprobe@sha256:c966d36f5353f71033c1a7b0321a9a670f8929af8740f714e455902b312a82a6'
nfs_plugin_local='localhost/zettide-tests/nfsplugin:sha256-473611fde6406ff0'
registrar_local='localhost/zettide-tests/csi-node-driver-registrar:sha256-0fc05c749072bea8'
liveness_local='localhost/zettide-tests/livenessprobe:sha256-c966d36f5353f710'
workload_local='localhost/zettide-tests/busybox:sha256-b7f3d86d6e84fc17'

[[ $EUID -eq 0 ]] || {
    echo "CSI NFS kind verification requires root" >&2
    exit 2
}
if [[ ! $nconnect =~ ^[1-9][0-9]*$ ]] || ((nconnect > 16)); then
    echo "ZETTIDE_NFS_NCONNECT must be between 1 and 16" >&2
    exit 2
fi
if [[ ! $rpc_ioq_thrd_min =~ ^[1-9][0-9]*$ || ! $rpc_ioq_thrd_max =~ ^[1-9][0-9]*$ ]] ||
    ((rpc_ioq_thrd_min < 2 || rpc_ioq_thrd_min > rpc_ioq_thrd_max)); then
    echo "NFS RPC thread limits must satisfy 2 <= min <= max" >&2
    exit 2
fi
for path in "$cli" "$kind" "$kubectl" "$ganesha_build/ganesha.nfsd" \
    "$ganesha_build/FSAL/FSAL_ZETTIDE/libfsalzettide.so"; do
    [[ -x $path || $path == *.so && -f $path ]] || {
        echo "required executable or module is unavailable: $path" >&2
        exit 2
    }
done
for manifest in rbac-csi-nfs.yaml csi-nfs-driverinfo.yaml csi-nfs-node.yaml; do
    [[ -f $manifest_dir/$manifest ]] || {
        echo "required NFS CSI manifest is unavailable: $manifest" >&2
        exit 2
    }
done
for command in docker grep jq python3 rpcbind rpcinfo sha256sum timeout; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done
exec 9>/var/lock/zettide-kind.lock
flock --nonblock 9 || {
    echo "another kind integration test owns the host lock" >&2
    exit 1
}

mkdir -p "$log_dir"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-csi-kind.XXXXXX")
image="$tmp/filesystem.blob"
config="$tmp/ganesha.conf"
pid_file="$tmp/ganesha.pid"
kubeconfig="$tmp/kubeconfig"
kind_config="$tmp/kind.yaml"
storage_manifest="$tmp/storage.yaml"
workload_manifest="$tmp/workloads.yaml"
verifier_manifest="$tmp/verifier.yaml"
patched_node_manifest="$tmp/csi-nfs-node.yaml"
cluster_name="zettide-csi-${BASHPID}"
namespace=zettide-csi
pv_name=zettide-nfs-static
cluster_created=false
rpcbind_started=false
rpcbind_pid=
ganesha_launcher_pid=
ganesha_pid=
ganesha_start_count=0
ganesha_running=false
recovery_pid=
gateway=
subnet=
nfs_port=
mnt_port=
rquota_port=
worker_one="${cluster_name}-worker"
worker_two="${cluster_name}-worker2"
test_succeeded=false
export KUBECONFIG=$kubeconfig

stop_ganesha() {
    local stopped_pid=$ganesha_pid
    if [[ -n $ganesha_pid ]]; then
        kill -TERM "$ganesha_pid" 2>/dev/null || true
        for _ in $(seq 1 200); do
            kill -0 "$ganesha_pid" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$ganesha_pid" 2>/dev/null; then
            kill -KILL "$ganesha_pid" 2>/dev/null || true
        fi
        if kill -0 "$ganesha_pid" 2>/dev/null; then
            echo "failed to stop NFS-Ganesha process $ganesha_pid" >&2
            return 1
        fi
        ganesha_pid=
    fi
    if [[ -n $ganesha_launcher_pid ]]; then
        wait "$ganesha_launcher_pid" 2>/dev/null || true
        ganesha_launcher_pid=
    fi
    if [[ -n $stopped_pid ]]; then ganesha_running=false; fi
}

collect_logs() {
    [[ $cluster_created == true ]] || return 0
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s version --output=yaml \
        >"$log_dir/kubectl-version.yaml" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s get nodes,pods,pv,pvc,csidrivers \
        -A -o wide >"$log_dir/kubernetes-objects.log" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s get events -A \
        --sort-by=.lastTimestamp >"$log_dir/kubernetes-events.log" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s describe pv "$pv_name" \
        >"$log_dir/pv-describe.log" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s describe pvc -n "$namespace" \
        zettide-nfs >"$log_dir/pvc-describe.log" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s logs -n kube-system \
        -l app=csi-nfs-node --all-containers=true --prefix=true \
        >"$log_dir/csi-nfs-node.log" 2>&1 || true
    for node in "${cluster_name}-control-plane" "$worker_one" "$worker_two"; do
        timeout --kill-after=2s 15s docker exec "$node" crictl images --output=json \
            >"$log_dir/${node}-images.json" 2>&1 || true
        timeout --kill-after=2s 15s docker exec "$node" grep -F "$gateway:/zettide" /proc/self/mountinfo \
            >"$log_dir/${node}-nfs-mounts.log" 2>&1 || true
    done
    timeout --kill-after=5s 120s "$kind" export logs "$log_dir/kind" --name "$cluster_name" \
        >"$log_dir/kind-export.log" 2>&1 || true
}

cleanup() {
    local status=$?
    local cleanup_status=0
    trap - EXIT INT TERM
    set +e
    if [[ $cluster_created == true && -s $config && $ganesha_running != true ]]; then
        start_ganesha || cleanup_status=1
    fi
    if [[ -n $recovery_pid ]]; then
        for _ in $(seq 1 50); do
            kill -0 "$recovery_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$recovery_pid" 2>/dev/null; then kill "$recovery_pid" 2>/dev/null || true; fi
        wait "$recovery_pid" 2>/dev/null || true
        recovery_pid=
    fi
    collect_logs
    if [[ $cluster_created == true ]]; then
        timeout --kill-after=2s 60s "$kubectl" --request-timeout=15s delete namespace "$namespace" \
            --ignore-not-found=true --wait=true >"$log_dir/namespace-delete.log" 2>&1 || true
        if ! timeout --kill-after=5s 120s "$kind" delete cluster --name "$cluster_name" \
            >"$log_dir/kind-delete.log" 2>&1; then
            cleanup_status=1
            for node in "${cluster_name}-control-plane" "$worker_one" "$worker_two"; do
                timeout --kill-after=2s 30s docker rm --force "$node" \
                    >>"$log_dir/kind-delete.log" 2>&1 || true
            done
        fi
    fi
    stop_ganesha || cleanup_status=1
    if [[ $rpcbind_started == true && -n $rpcbind_pid ]]; then
        kill -TERM "$rpcbind_pid" 2>/dev/null || cleanup_status=1
        wait "$rpcbind_pid" 2>/dev/null || true
        if kill -0 "$rpcbind_pid" 2>/dev/null; then cleanup_status=1; fi
    fi
    if [[ -f $image ]]; then
        "$cli" check "$image" >"$log_dir/final-check.log" 2>&1 || cleanup_status=1
    fi
    {
        echo "cluster=$cluster_name"
        echo "gateway=$gateway"
        echo "subnet=$subnet"
        echo "nfs_port=$nfs_port"
        echo "mount_port=$mnt_port"
        echo "nconnect=$nconnect"
        echo "test_succeeded=$test_succeeded"
        echo "command_status=$status"
        echo "cleanup_status=$cleanup_status"
    } >"$log_dir/lifecycle.log"
    rm -rf "$tmp"
    if [[ $cleanup_status -ne 0 ]]; then
        echo "CSI NFS kind cleanup or final filesystem check failed" >&2
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

choose_port() {
    python3 - "$gateway" <<'PY'
import socket
import sys

with socket.socket() as listener:
    listener.bind((sys.argv[1], 0))
    print(listener.getsockname()[1])
PY
}

start_ganesha() {
    local current_log
    ((ganesha_start_count += 1))
    current_log="$log_dir/ganesha-${ganesha_start_count}.log"
    rm -f "$pid_file"
    : >"$current_log"
    "$ganesha_build/ganesha.nfsd" -F -f "$config" -L "$current_log" -p "$pid_file" -N EVENT &
    ganesha_launcher_pid=$!
    for _ in $(seq 1 300); do
        if [[ -s $pid_file ]]; then
            ganesha_pid=$(<"$pid_file")
            if kill -0 "$ganesha_pid" 2>/dev/null &&
                rpcinfo -p "$gateway" 2>/dev/null |
                    grep -Eq "^[[:space:]]*100003[[:space:]]+3[[:space:]]+tcp[[:space:]]+$nfs_port([[:space:]]|$)" &&
                rpcinfo -p "$gateway" 2>/dev/null |
                    grep -Eq "^[[:space:]]*100005[[:space:]]+3[[:space:]]+tcp[[:space:]]+$mnt_port([[:space:]]|$)"; then
                ganesha_running=true
                return 0
            fi
        fi
        kill -0 "$ganesha_launcher_pid" 2>/dev/null || break
        sleep 0.1
    done
    cat "$current_log" >&2
    echo "NFS-Ganesha readiness timeout" >&2
    return 1
}

assert_no_node_mounts() {
    local mountinfo node
    for node in "${cluster_name}-control-plane" "$worker_one" "$worker_two"; do
        if ! mountinfo=$(timeout --kill-after=2s 10s docker exec "$node" cat /proc/self/mountinfo); then
            echo "failed to inspect mounts on kind node: $node" >&2
            return 1
        fi
        if grep -Fq "$gateway:/zettide" <<<"$mountinfo"; then
            echo "NFS mount remains on kind node: $node" >&2
            grep -F "$gateway:/zettide" <<<"$mountinfo" >&2 || true
            return 1
        fi
    done
}

record_active_mounts() {
    local mount_line node phase=$1
    shift
    for node in "$@"; do
        mount_line=$(timeout --kill-after=2s 10s docker exec "$node" grep -F \
            "$gateway:/zettide" /proc/mounts)
        printf '%s\n' "$mount_line" >"$log_dir/${phase}-${node}-mount.log"
        [[ $mount_line == *"vers=3"* && $mount_line == *"hard"* &&
            $mount_line == *"proto=tcp"* && $mount_line == *"mountproto=tcp"* &&
            $mount_line == *"port=$nfs_port"* && $mount_line == *"mountport=$mnt_port"* &&
            $mount_line == *"nolock"* && $mount_line == *"nconnect=$nconnect"* ]] || {
            echo "kind node has unexpected NFS mount options: $node" >&2
            return 1
        }
    done
}

wait_for_no_node_mounts() {
    for _ in $(seq 1 120); do
        if assert_no_node_mounts 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    assert_no_node_mounts
}

wait_for_file() {
    local pod=$1
    local path=$2
    for _ in $(seq 1 180); do
        if "$kubectl" exec -n "$namespace" "$pod" -- test -f "$path" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    "$kubectl" describe pod -n "$namespace" "$pod" >&2 || true
    echo "timed out waiting for $pod:$path" >&2
    return 1
}

pull_image() {
    local image_ref=$1
    for _ in 1 2 3; do
        if timeout --kill-after=5s 600s docker pull "$image_ref"; then
            return 0
        fi
        sleep 5
    done
    echo "failed to pull pinned image on the host: $image_ref" >&2
    return 1
}

cat >"$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

"$kind" version >"$log_dir/kind-version.log"
docker info >"$log_dir/docker-info.log"
if command -v getenforce >/dev/null; then getenforce >"$log_dir/selinux.log"; fi
sha256sum "$manifest_dir"/*.yaml >"$log_dir/csi-manifest-sha256.log"
jq -n \
    --arg kind_node_image "$kind_node_image" \
    --arg workload_image "$workload_image" \
    --arg nfs_plugin_image "$nfs_plugin_image" \
    --arg registrar_image "$registrar_image" \
    --arg liveness_image "$liveness_image" \
    --arg nfs_plugin_local "$nfs_plugin_local" \
    --arg registrar_local "$registrar_local" \
    --arg liveness_local "$liveness_local" \
    --arg workload_local "$workload_local" \
    '{kind_node_image: $kind_node_image, workload_image: $workload_image,
      nfs_plugin_image: $nfs_plugin_image, registrar_image: $registrar_image,
      liveness_image: $liveness_image,
      local_refs: [$nfs_plugin_local, $registrar_local, $liveness_local, $workload_local]}' \
    >"$log_dir/images.json"
for image_ref in "$nfs_plugin_image" "$registrar_image" "$liveness_image" "$workload_image"; do
    pull_image "$image_ref"
done >"$log_dir/host-image-pull.log" 2>&1
docker tag "$nfs_plugin_image" "$nfs_plugin_local"
docker tag "$registrar_image" "$registrar_local"
docker tag "$liveness_image" "$liveness_local"
docker tag "$workload_image" "$workload_local"

cluster_created=true
timeout --kill-after=10s 900s "$kind" create cluster --name "$cluster_name" \
    --image "$kind_node_image" --config "$kind_config" --kubeconfig "$kubeconfig" --wait 5m \
    >"$log_dir/kind-create.log" 2>&1
timeout --kill-after=5s 600s "$kind" load docker-image \
    "$nfs_plugin_local" "$registrar_local" "$liveness_local" "$workload_local" \
    --name "$cluster_name" >"$log_dir/kind-image-load.log" 2>&1
for node in "${cluster_name}-control-plane" "$worker_one" "$worker_two"; do
    for image_ref in "$nfs_plugin_local" "$registrar_local" "$liveness_local" "$workload_local"; do
        docker exec "$node" crictl inspecti "$image_ref" >/dev/null
    done
done

docker network inspect kind >"$log_dir/kind-network.json"
read -r gateway subnet < <(python3 - "$log_dir/kind-network.json" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1]) as source:
    networks = json.load(source)
for config in networks[0]["IPAM"]["Config"]:
    gateway = config.get("Gateway", "")
    subnet = config.get("Subnet", "")
    if gateway and subnet and ipaddress.ip_address(gateway).version == 4:
        print(gateway, subnet)
        break
PY
) || true
[[ $gateway =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $subnet == */* ]] || {
    echo "kind did not provide an IPv4 gateway and subnet" >&2
    exit 1
}

nfs_port=$(choose_port)
mnt_port=$(choose_port)
while [[ $mnt_port == "$nfs_port" ]]; do mnt_port=$(choose_port); done
rquota_port=$(choose_port)
while [[ $rquota_port == "$nfs_port" || $rquota_port == "$mnt_port" ]]; do
    rquota_port=$(choose_port)
done

if ! rpcinfo -p "$gateway" >/dev/null 2>&1; then
    if rpcinfo -p 127.0.0.1 >/dev/null 2>&1; then
        echo "the existing rpcbind is not reachable from the kind gateway" >&2
        exit 1
    fi
    rpcbind -f >"$log_dir/rpcbind.log" 2>&1 &
    rpcbind_pid=$!
    rpcbind_started=true
    for _ in $(seq 1 100); do
        rpcinfo -p "$gateway" >/dev/null 2>&1 && break
        sleep 0.05
    done
    rpcinfo -p "$gateway" >/dev/null 2>&1 || {
        echo "rpcbind failed to start on the kind gateway" >&2
        exit 1
    }
fi

"$cli" format "$image" --size 4GiB --name-profile portable-v1 >"$log_dir/format.log"
"$cli" info "$image" >"$log_dir/filesystem-info.log"
filesystem_uuid=$(grep '^UUID: ' "$log_dir/filesystem-info.log")
filesystem_uuid=${filesystem_uuid#UUID: }
[[ $filesystem_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    echo "Zettide did not return a filesystem UUID" >&2
    exit 1
}

cat >"$config" <<EOF
NFS_Core_Param {
    NFS_Port = $nfs_port;
    MNT_Port = $mnt_port;
    Rquota_Port = $rquota_port;
    Bind_Addr = $gateway;
    Protocols = 3;
    Enable_UDP = false;
    Plugins_Dir = "$ganesha_build/FSAL/FSAL_ZETTIDE";
    Enable_NFSACL = false;
    Allow_Set_Io_Flusher_Fail = true;
    rpc_ioq_thrdmin = $rpc_ioq_thrd_min;
    RPC_Ioq_ThrdMax = $rpc_ioq_thrd_max;
}

NFSv4 {
    RecoveryRoot = "$tmp";
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

    CLIENT {
        Clients = $subnet;
        Access_Type = RW;
        Squash = No_Root_Squash;
    }

    FSAL {
        name = ZETTIDE;
        Target = "$image";
        Writable = true;
        Stable_Write_Batch_Us = 20000;
    }
}
EOF
cp "$config" "$log_dir/ganesha.conf"
start_ganesha

python3 - "$manifest_dir/csi-nfs-node.yaml" "$patched_node_manifest" \
    "$liveness_local" "$registrar_local" "$nfs_plugin_local" <<'PY'
import pathlib
import sys

source, destination, liveness, registrar, plugin = sys.argv[1:]
text = pathlib.Path(source).read_text()
replacements = {
    "registry.k8s.io/sig-storage/livenessprobe:v2.19.0": liveness,
    "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0": registrar,
    "registry.k8s.io/sig-storage/nfsplugin:v4.13.4": plugin,
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit(f"expected one image reference: {old}")
    text = text.replace(old, new)
text = text.replace('          imagePullPolicy: "IfNotPresent"\n', '')
for image in replacements.values():
    text = text.replace(f"          image: {image}\n", f"          image: {image}\n          imagePullPolicy: Never\n")
pathlib.Path(destination).write_text(text)
PY
cp "$patched_node_manifest" "$log_dir/csi-nfs-node-pinned.yaml"

"$kubectl" apply -f "$manifest_dir/rbac-csi-nfs.yaml"
"$kubectl" apply -f "$manifest_dir/csi-nfs-driverinfo.yaml"
"$kubectl" apply -f "$patched_node_manifest"
"$kubectl" rollout status daemonset/csi-nfs-node -n kube-system --timeout=10m

cat >"$storage_manifest" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $pv_name
  annotations:
    pv.kubernetes.io/provisioned-by: nfs.csi.k8s.io
spec:
  capacity:
    storage: 1Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - nfsvers=3
    - nolock
    - proto=tcp
    - mountproto=tcp
    - port=$nfs_port
    - mountport=$mnt_port
    - hard
    - timeo=50
    - retrans=2
    - nconnect=$nconnect
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: zettide://filesystem/$filesystem_uuid
    readOnly: false
    volumeAttributes:
      server: $gateway
      share: /zettide
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zettide-nfs
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: ""
  volumeName: $pv_name
EOF
cp "$storage_manifest" "$log_dir/storage.yaml"
"$kubectl" apply -f "$storage_manifest"
"$kubectl" wait pvc/zettide-nfs -n "$namespace" --for=jsonpath='{.status.phase}'=Bound --timeout=2m

cat >"$workload_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: writer-a
  namespace: $namespace
spec:
  nodeName: $worker_one
  restartPolicy: Never
  containers:
    - name: writer
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; dd if=/dev/urandom of=/data/from-a.bin bs=1M count=4;
          cd /data; sha256sum from-a.bin > from-a.sha256; touch a-ready; sleep 3600
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zettide-nfs
---
apiVersion: v1
kind: Pod
metadata:
  name: writer-b
  namespace: $namespace
spec:
  nodeName: $worker_two
  restartPolicy: Never
  containers:
    - name: writer
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; while [ ! -f /data/a-ready ]; do sleep 1; done; cd /data;
          sha256sum -c from-a.sha256; dd if=/dev/urandom of=from-b.bin bs=1M count=4;
          sha256sum from-b.bin > from-b.sha256; touch b-ready; sleep 3600
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zettide-nfs
EOF
cp "$workload_manifest" "$log_dir/workloads.yaml"
"$kubectl" apply -f "$workload_manifest"
"$kubectl" wait pod/writer-a pod/writer-b -n "$namespace" --for=condition=Ready --timeout=10m
wait_for_file writer-a /data/a-ready
wait_for_file writer-b /data/b-ready
record_active_mounts writers "$worker_one" "$worker_two"
"$kubectl" exec -n "$namespace" writer-a -- sh -c 'cd /data && sha256sum -c from-b.sha256'
"$kubectl" exec -n "$namespace" writer-b -- sh -c 'cd /data && sha256sum -c from-a.sha256'

stop_ganesha
timeout --kill-after=5s 180s "$kubectl" exec -n "$namespace" writer-a -- \
    sh -c 'touch /tmp/recovery-started; printf recovered > /data/recovery.txt; sync /data/recovery.txt' \
    >"$log_dir/ganesha-recovery.log" 2>&1 &
recovery_pid=$!
for _ in $(seq 1 30); do
    "$kubectl" exec -n "$namespace" writer-a -- test -f /tmp/recovery-started >/dev/null 2>&1 && break
    sleep 1
done
"$kubectl" exec -n "$namespace" writer-a -- test -f /tmp/recovery-started
kill -0 "$recovery_pid" 2>/dev/null || {
    wait "$recovery_pid" || true
    recovery_pid=
    echo "NFS I/O did not wait for the stopped Ganesha server" >&2
    exit 1
}
start_ganesha
wait "$recovery_pid"
recovery_pid=
[[ $("$kubectl" exec -n "$namespace" writer-b -- cat /data/recovery.txt) == recovered ]]

old_csi_pod=$("$kubectl" get pods -n kube-system -l app=csi-nfs-node \
    --field-selector "spec.nodeName=$worker_one" -o jsonpath='{.items[0].metadata.name}')
old_csi_uid=$("$kubectl" get pod -n kube-system "$old_csi_pod" -o jsonpath='{.metadata.uid}')
"$kubectl" logs -n kube-system "$old_csi_pod" --all-containers=true \
    >"$log_dir/csi-nfs-node-before-restart.log" 2>&1 || true
"$kubectl" delete pod -n kube-system "$old_csi_pod" --wait=true
"$kubectl" rollout status daemonset/csi-nfs-node -n kube-system --timeout=10m
new_csi_uid=$("$kubectl" get pods -n kube-system -l app=csi-nfs-node \
    --field-selector "spec.nodeName=$worker_one" -o jsonpath='{.items[0].metadata.uid}')
[[ $new_csi_uid != "$old_csi_uid" ]] || {
    echo "CSI node pod was not replaced" >&2
    exit 1
}
"$kubectl" exec -n "$namespace" writer-a -- sh -c 'cd /data && sha256sum -c from-a.sha256 from-b.sha256'

cat >>"$workload_manifest" <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: reader-ro
  namespace: $namespace
spec:
  nodeName: $worker_two
  restartPolicy: Never
  containers:
    - name: reader
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; cd /data; sha256sum -c from-a.sha256 from-b.sha256;
          if touch rejected-write; then exit 1; fi; touch /status/ready; sleep 3600
      readinessProbe:
        exec:
          command: ["test", "-f", "/status/ready"]
        periodSeconds: 1
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
        - name: status
          mountPath: /status
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zettide-nfs
        readOnly: true
    - name: status
      emptyDir: {}
EOF
cp "$workload_manifest" "$log_dir/workloads.yaml"
"$kubectl" apply -f "$workload_manifest"
"$kubectl" wait pod/reader-ro -n "$namespace" --for=condition=Ready --timeout=5m
record_active_mounts readonly "$worker_one" "$worker_two"
if "$kubectl" exec -n "$namespace" writer-a -- test -e /data/rejected-write; then
    echo "read-only CSI mount created a file" >&2
    exit 1
fi

for pod in writer-a writer-b reader-ro; do
    "$kubectl" logs -n "$namespace" "$pod" >"$log_dir/${pod}.log" 2>&1 || true
done

"$kubectl" delete pod -n "$namespace" writer-a writer-b reader-ro --wait=true
wait_for_no_node_mounts
stop_ganesha
"$cli" check "$image" >"$log_dir/offline-check.log"
start_ganesha

cat >"$verifier_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: verifier
  namespace: $namespace
spec:
  nodeName: $worker_one
  restartPolicy: Never
  containers:
    - name: verifier
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; cd /data; sha256sum -c from-a.sha256 from-b.sha256;
          test "\$(cat recovery.txt)" = recovered;
          touch /status/ready; sleep 3600
      readinessProbe:
        exec:
          command: ["test", "-f", "/status/ready"]
        periodSeconds: 1
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
        - name: status
          mountPath: /status
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zettide-nfs
        readOnly: true
    - name: status
      emptyDir: {}
EOF
cp "$verifier_manifest" "$log_dir/verifier.yaml"
"$kubectl" apply -f "$verifier_manifest"
"$kubectl" wait pod/verifier -n "$namespace" --for=condition=Ready --timeout=5m
"$kubectl" logs -n "$namespace" verifier >"$log_dir/verifier-before-rebind.log" 2>&1 || true
"$kubectl" delete pod/verifier -n "$namespace" --wait=true
wait_for_no_node_mounts
"$kubectl" delete pvc/zettide-nfs -n "$namespace" --wait=true
"$kubectl" wait pv/"$pv_name" --for=jsonpath='{.status.phase}'=Released --timeout=2m
"$kubectl" delete pv "$pv_name" --wait=true
"$kubectl" apply -f "$storage_manifest"
"$kubectl" wait pvc/zettide-nfs -n "$namespace" --for=jsonpath='{.status.phase}'=Bound --timeout=2m
"$kubectl" apply -f "$verifier_manifest"
"$kubectl" wait pod/verifier -n "$namespace" --for=condition=Ready --timeout=5m
"$kubectl" logs -n "$namespace" verifier >"$log_dir/verifier-after-rebind.log" 2>&1 || true
"$kubectl" delete pod/verifier -n "$namespace" --wait=true
wait_for_no_node_mounts
"$kubectl" delete pvc/zettide-nfs -n "$namespace" --wait=true
"$kubectl" delete pv "$pv_name" --wait=true
stop_ganesha
"$cli" check "$image" >"$log_dir/post-kubernetes-check.log"
test_succeeded=true
echo "static NFS CSI kind integration succeeded"
