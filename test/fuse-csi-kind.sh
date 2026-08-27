#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 4 ]] || {
    echo "usage: fuse-csi-kind.sh CLI CSI_NODE KIND KUBECTL" >&2
    exit 2
}

cli=$1
csi_node=$2
kind=$3
kubectl=$4
log_dir=${ZETTIDE_TEST_LOG_DIR:?ZETTIDE_TEST_LOG_DIR is required}
kind_node_image='kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5'
driver_base_image='registry.fedoraproject.org/fedora:44@sha256:f9c9cacc1fc5e775dad494a05e747e1b63b061a63c1d8705965816ed4184543c'
registrar_image='registry.k8s.io/sig-storage/csi-node-driver-registrar@sha256:0fc05c749072bea889beffc97499f6836f74aebe351c78ff8d90d671c35f04da'
liveness_image='registry.k8s.io/sig-storage/livenessprobe@sha256:c966d36f5353f71033c1a7b0321a9a670f8929af8740f714e455902b312a82a6'
workload_image='docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f'
registrar_local='localhost/zettide-test/csi-node-driver-registrar:sha256-0fc05c749072bea8'
liveness_local='localhost/zettide-test/livenessprobe:sha256-c966d36f5353f710'
workload_local='localhost/zettide-test/busybox:sha256-b7f3d86d6e84fc17'
driver_local='localhost/zettide-test/zettide-csi-fuse:v0.1.0'

[[ $EUID -eq 0 ]] || {
    echo "FUSE CSI kind verification requires root" >&2
    exit 2
}
for path in "$cli" "$csi_node" "$kind" "$kubectl"; do
    [[ -x $path ]] || {
        echo "required executable is unavailable: $path" >&2
        exit 2
    }
done
for command in docker flock jq mountpoint sha256sum timeout; do
    command -v "$command" >/dev/null || {
        echo "$command is required" >&2
        exit 2
    }
done
[[ -c /dev/fuse && -r /dev/fuse && -w /dev/fuse ]] || {
    echo "/dev/fuse is unavailable" >&2
    exit 2
}

exec 9>/var/lock/zettide-kind.lock
flock --nonblock 9 || {
    echo "another kind integration test owns the host lock" >&2
    exit 1
}

mkdir -p "$log_dir"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-fuse-csi.XXXXXX")
target_dir="$tmp/targets"
image="$target_dir/filesystem.blob"
kubeconfig="$tmp/kubeconfig"
kind_config="$tmp/kind.yaml"
driver_manifest="$tmp/driver.yaml"
storage_manifest="$tmp/storage.yaml"
writer_manifest="$tmp/writer.yaml"
reader_manifest="$tmp/reader.yaml"
verifier_manifest="$tmp/verifier.yaml"
cluster_name="zettide-fuse-csi-${BASHPID}"
namespace=zettide-fuse-csi
pv_name=zettide-fuse-static
worker="${cluster_name}-worker"
cluster_created=false
test_succeeded=false
export KUBECONFIG=$kubeconfig

collect_logs() {
    [[ $cluster_created == true ]] || return 0
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s version --output=yaml \
        >"$log_dir/kubectl-version.yaml" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s get nodes,pods,pv,pvc,csidrivers \
        -A -o wide >"$log_dir/kubernetes-objects.log" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s get events -A \
        --sort-by=.lastTimestamp >"$log_dir/kubernetes-events.log" 2>&1 || true
    timeout --kill-after=2s 30s "$kubectl" --request-timeout=15s logs -n kube-system \
        -l app=zettide-csi-fuse --all-containers=true --prefix=true \
        >"$log_dir/zettide-csi-node.log" 2>&1 || true
    local csi_pod
    csi_pod=$("$kubectl" get pod -n kube-system -l app=zettide-csi-fuse \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n $csi_pod ]]; then
        # shellcheck disable=SC2016 # Expanded by the container shell.
        timeout --kill-after=2s 15s "$kubectl" exec -n kube-system "$csi_pod" -c zettide-csi -- \
            sh -c 'for file in /var/lib/zettide-csi/state/*; do [ ! -f "$file" ] || { echo "=== $file"; cat "$file"; }; done' \
            >"$log_dir/csi-state.log" 2>&1 || true
    fi
    for node in "${cluster_name}-control-plane" "$worker"; do
        timeout --kill-after=2s 15s docker exec "$node" crictl images --output=json \
            >"$log_dir/${node}-images.json" 2>&1 || true
        timeout --kill-after=2s 15s docker exec "$node" sh -c \
            'grep -E "fuse(\\.| )" /proc/self/mountinfo || true' \
            >"$log_dir/${node}-fuse-mounts.log" 2>&1 || true
    done
    timeout --kill-after=5s 120s "$kind" export logs "$log_dir/kind" --name "$cluster_name" \
        >"$log_dir/kind-export.log" 2>&1 || true
}

cleanup() {
    local status=$?
    local cleanup_status=0
    trap - EXIT INT TERM
    set +e
    collect_logs
    if [[ $cluster_created == true ]]; then
        timeout --kill-after=2s 90s "$kubectl" --request-timeout=15s delete namespace "$namespace" \
            --ignore-not-found=true --wait=true >"$log_dir/namespace-delete.log" 2>&1 || true
        timeout --kill-after=2s 60s "$kubectl" --request-timeout=15s delete daemonset \
            zettide-csi-fuse -n kube-system --ignore-not-found=true --wait=true \
            >"$log_dir/daemonset-delete.log" 2>&1 || true
        if ! timeout --kill-after=5s 120s "$kind" delete cluster --name "$cluster_name" \
            >"$log_dir/kind-delete.log" 2>&1; then
            cleanup_status=1
            for node in "${cluster_name}-control-plane" "$worker"; do
                timeout --kill-after=2s 30s docker rm --force "$node" \
                    >>"$log_dir/kind-delete.log" 2>&1 || true
            done
        fi
    fi
    if [[ -f $image ]]; then
        "$cli" check "$image" >"$log_dir/final-check.log" 2>&1 || cleanup_status=1
    fi
    {
        echo "cluster=$cluster_name"
        echo "worker=$worker"
        echo "test_succeeded=$test_succeeded"
        echo "command_status=$status"
        echo "cleanup_status=$cleanup_status"
    } >"$log_dir/lifecycle.log"
    rm -rf "$tmp"
    if [[ $cleanup_status -ne 0 ]]; then
        echo "FUSE CSI kind cleanup or final filesystem check failed" >&2
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

csi_pod_name() {
    "$kubectl" get pods -n kube-system -l app=zettide-csi-fuse \
        --field-selector "spec.nodeName=$worker" -o jsonpath='{.items[0].metadata.name}'
}

state_json() {
    local pod
    pod=$(csi_pod_name)
    # shellcheck disable=SC2016 # Expanded by the container shell.
    "$kubectl" exec -n kube-system "$pod" -c zettide-csi -- sh -c \
        'set -- /var/lib/zettide-csi/state/*.json; [ -f "$1" ] && cat "$1"'
}

current_fuse_pid() {
    state_json | jq -er '.pid | select(. > 0)'
}

wait_for_new_fuse_pid() {
    local old_pid=$1
    local mount_line new_pid state target
    for _ in $(seq 1 180); do
        state=$(state_json 2>/dev/null || true)
        new_pid=$(jq -er '.pid | select(. > 0)' <<<"$state" 2>/dev/null || true)
        target=$(jq -er .target <<<"$state" 2>/dev/null || true)
        mount_line=$(docker exec "$worker" grep -F " $target " /proc/mounts 2>/dev/null || true)
        if [[ -n $new_pid && -n $target && $new_pid != "$old_pid" &&
            $mount_line == *" fuse.zettide "* ]]; then
            echo "$new_pid"
            return 0
        fi
        sleep 1
    done
    echo "timed out waiting for FUSE process recovery" >&2
    return 1
}

wait_for_no_publication() {
    local pod
    for _ in $(seq 1 120); do
        pod=$(csi_pod_name 2>/dev/null || true)
        # shellcheck disable=SC2016 # Expanded by the container shell.
        if [[ -n $pod ]] &&
            "$kubectl" exec -n kube-system "$pod" -c zettide-csi -- sh -c \
                'set -- /var/lib/zettide-csi/state/*.json; [ ! -f "$1" ]' >/dev/null 2>&1 &&
            ! docker exec "$worker" grep -Fq 'fuse.zettide' /proc/self/mountinfo; then
            return 0
        fi
        sleep 1
    done
    echo "FUSE publication remained after pod deletion" >&2
    docker exec "$worker" grep -F 'fuse.zettide' /proc/self/mountinfo >&2 || true
    return 1
}

record_fuse_mount() {
    local phase=$1
    local mount_line target
    target=$(state_json | jq -er .target)
    mount_line=$(docker exec "$worker" grep -F " $target " /proc/mounts)
    printf '%s\n' "$mount_line" >"$log_dir/${phase}-mount.log"
    [[ $mount_line == *" fuse.zettide "* && $mount_line == *"default_permissions"* &&
        $mount_line == *"allow_other"* ]] || {
        echo "FUSE publication has unexpected mount options" >&2
        return 1
    }
}

mkdir -p "$target_dir"
"$cli" format "$image" --size 4GiB --name-profile portable-v1 >"$log_dir/format.log"
"$cli" info "$image" >"$log_dir/filesystem-info.log"
filesystem_uuid=$(grep '^UUID: ' "$log_dir/filesystem-info.log")
filesystem_uuid=${filesystem_uuid#UUID: }
[[ $filesystem_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    echo "Zettide did not return a filesystem UUID" >&2
    exit 1
}

for image_ref in "$kind_node_image" "$driver_base_image" "$registrar_image" "$liveness_image" "$workload_image"; do
    pull_image "$image_ref"
done >"$log_dir/host-image-pull.log" 2>&1
docker tag "$registrar_image" "$registrar_local"
docker tag "$liveness_image" "$liveness_local"
docker tag "$workload_image" "$workload_local"
docker build --build-arg "BASE_IMAGE=$driver_base_image" --tag "$driver_local" csi \
    >"$log_dir/driver-image-build.log" 2>&1
docker run --rm --entrypoint /bin/sh "$driver_local" -c \
    'ldd /usr/local/bin/zettide && /usr/local/bin/zettide-csi-node --help >/dev/null' \
    >"$log_dir/driver-image-smoke.log" 2>&1
docker image inspect "$driver_local" >"$log_dir/driver-image-inspect.json"

cat >"$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    extraMounts:
      - hostPath: /dev/fuse
        containerPath: /dev/fuse
      - hostPath: $target_dir
        containerPath: /var/lib/zettide-csi-targets
EOF
cp "$kind_config" "$log_dir/kind.yaml"
"$kind" version >"$log_dir/kind-version.log"
docker info >"$log_dir/docker-info.log"
if command -v getenforce >/dev/null; then getenforce >"$log_dir/selinux.log"; fi

cluster_created=true
timeout --kill-after=10s 900s "$kind" create cluster --name "$cluster_name" \
    --image "$kind_node_image" --config "$kind_config" --kubeconfig "$kubeconfig" --wait 5m \
    >"$log_dir/kind-create.log" 2>&1
timeout --kill-after=5s 600s "$kind" load docker-image \
    "$driver_local" "$registrar_local" "$liveness_local" "$workload_local" \
    --name "$cluster_name" >"$log_dir/kind-image-load.log" 2>&1
for node in "${cluster_name}-control-plane" "$worker"; do
    for image_ref in "$driver_local" "$registrar_local" "$liveness_local" "$workload_local"; do
        docker exec "$node" crictl inspecti "$image_ref" >/dev/null
    done
done
docker exec "$worker" test -c /dev/fuse
"$kubectl" label node "$worker" zettide.io/fuse-csi=true

cat >"$driver_manifest" <<EOF
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: fuse.csi.zettide.io
spec:
  attachRequired: false
  podInfoOnMount: false
  fsGroupPolicy: None
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: zettide-csi-fuse
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: zettide-csi-fuse
  template:
    metadata:
      labels:
        app: zettide-csi-fuse
    spec:
      terminationGracePeriodSeconds: 60
      hostPID: true
      nodeSelector:
        zettide.io/fuse-csi: "true"
      containers:
        - name: node-driver-registrar
          image: $registrar_local
          imagePullPolicy: Never
          args:
            - --csi-address=/csi/csi.sock
            - --kubelet-registration-path=/var/lib/kubelet/plugins/fuse.csi.zettide.io/csi.sock
            - --v=2
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - name: registration-dir
              mountPath: /registration
        - name: liveness-probe
          image: $liveness_local
          imagePullPolicy: Never
          args:
            - --csi-address=/csi/csi.sock
            - --http-endpoint=:29654
            - --probe-timeout=3s
            - --v=2
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        - name: zettide-csi
          image: $driver_local
          imagePullPolicy: Never
          args:
            - --endpoint=unix:///csi/csi.sock
            - --node-id=\$(NODE_ID)
          env:
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          securityContext:
            privileged: true
            allowPrivilegeEscalation: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 29654
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - name: pods-mount-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: Bidirectional
            - name: state-dir
              mountPath: /var/lib/zettide-csi/state
            - name: target-dir
              mountPath: /var/lib/zettide-csi-targets
            - name: fuse-device
              mountPath: /dev/fuse
      volumes:
        - name: socket-dir
          hostPath:
            path: /var/lib/kubelet/plugins/fuse.csi.zettide.io
            type: DirectoryOrCreate
        - name: registration-dir
          hostPath:
            path: /var/lib/kubelet/plugins_registry
            type: Directory
        - name: pods-mount-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: Directory
        - name: state-dir
          hostPath:
            path: /var/lib/kubelet/plugins/fuse.csi.zettide.io/state
            type: DirectoryOrCreate
        - name: target-dir
          hostPath:
            path: /var/lib/zettide-csi-targets
            type: Directory
        - name: fuse-device
          hostPath:
            path: /dev/fuse
            type: CharDevice
EOF
cp "$driver_manifest" "$log_dir/driver.yaml"
"$kubectl" apply -f "$driver_manifest"
"$kubectl" rollout status daemonset/zettide-csi-fuse -n kube-system --timeout=5m

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
spec:
  capacity:
    storage: 1Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOncePod
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: zettide.io/fuse-csi
              operator: In
              values: ["true"]
  csi:
    driver: fuse.csi.zettide.io
    volumeHandle: zettide://filesystem/$filesystem_uuid
    volumeAttributes:
      zettide.io/target-path: /var/lib/zettide-csi-targets/filesystem.blob
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zettide-fuse
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOncePod
  resources:
    requests:
      storage: 1Gi
  storageClassName: ""
  volumeName: $pv_name
EOF
cp "$storage_manifest" "$log_dir/storage.yaml"
"$kubectl" apply -f "$storage_manifest"
"$kubectl" wait pvc/zettide-fuse -n "$namespace" --for=jsonpath='{.status.phase}'=Bound --timeout=2m

cat >"$writer_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: $namespace
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; cd /data;
          if [ ! -f payload.bin ]; then dd if=/dev/urandom of=payload.bin bs=1M count=4;
          sha256sum payload.bin > payload.sha256; sync; fi;
          sha256sum -c payload.sha256;
          touch /status/ready; sleep 3600
      readinessProbe:
        exec:
          command: ["test", "-f", "/status/ready"]
        periodSeconds: 1
      volumeMounts:
        - name: data
          mountPath: /data
        - name: status
          mountPath: /status
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zettide-fuse
    - name: status
      emptyDir: {}
EOF
cp "$writer_manifest" "$log_dir/writer.yaml"
"$kubectl" apply -f "$writer_manifest"
"$kubectl" wait pod/writer -n "$namespace" --for=condition=Ready --timeout=5m
[[ $("$kubectl" get pod/writer -n "$namespace" -o jsonpath='{.spec.nodeName}') == "$worker" ]]
record_fuse_mount writer
old_fuse_pid=$(current_fuse_pid)
"$kubectl" exec -n kube-system "$(csi_pod_name)" -c zettide-csi -- kill -KILL "$old_fuse_pid"
recovered_fuse_pid=$(wait_for_new_fuse_pid "$old_fuse_pid")
printf 'old_pid=%s\nnew_pid=%s\n' "$old_fuse_pid" "$recovered_fuse_pid" \
    >"$log_dir/fuse-recovery.log"

"$kubectl" delete pod/writer -n "$namespace" --wait=true
wait_for_no_publication
"$kubectl" apply -f "$writer_manifest"
"$kubectl" wait pod/writer -n "$namespace" --for=condition=Ready --timeout=5m
timeout --kill-after=5s 120s "$kubectl" exec -n "$namespace" writer -- \
    sh -c 'cd /data && sha256sum -c payload.sha256'

old_csi_pod=$(csi_pod_name)
old_csi_uid=$("$kubectl" get pod -n kube-system "$old_csi_pod" -o jsonpath='{.metadata.uid}')
old_fuse_pid=$(current_fuse_pid)
"$kubectl" logs -n kube-system "$old_csi_pod" --all-containers=true \
    >"$log_dir/csi-before-restart.log" 2>&1 || true
"$kubectl" delete pod -n kube-system "$old_csi_pod" --wait=true
"$kubectl" rollout status daemonset/zettide-csi-fuse -n kube-system --timeout=5m
new_csi_pod=$(csi_pod_name)
new_csi_uid=$("$kubectl" get pod -n kube-system "$new_csi_pod" -o jsonpath='{.metadata.uid}')
[[ $new_csi_uid != "$old_csi_uid" ]]
recovered_fuse_pid=$(wait_for_new_fuse_pid "$old_fuse_pid")
printf 'old_pod=%s\nnew_pod=%s\nold_pid=%s\nnew_pid=%s\n' \
    "$old_csi_pod" "$new_csi_pod" "$old_fuse_pid" "$recovered_fuse_pid" \
    >"$log_dir/csi-recovery.log"

"$kubectl" logs -n "$namespace" writer >"$log_dir/writer.log" 2>&1 || true
"$kubectl" delete pod/writer -n "$namespace" --wait=true
wait_for_no_publication
"$cli" check "$image" >"$log_dir/offline-check.log"

cat >"$reader_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: reader-ro
  namespace: $namespace
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; cd /data; sha256sum -c payload.sha256;
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
        claimName: zettide-fuse
        readOnly: true
    - name: status
      emptyDir: {}
EOF
cp "$reader_manifest" "$log_dir/reader.yaml"
"$kubectl" apply -f "$reader_manifest"
"$kubectl" wait pod/reader-ro -n "$namespace" --for=condition=Ready --timeout=5m
record_fuse_mount reader-ro
grep -q ' ro,' "$log_dir/reader-ro-mount.log"
"$kubectl" logs -n "$namespace" reader-ro >"$log_dir/reader-ro.log" 2>&1 || true
"$kubectl" delete pod/reader-ro -n "$namespace" --wait=true
wait_for_no_publication

"$kubectl" delete pvc/zettide-fuse -n "$namespace" --wait=true
"$kubectl" wait pv/"$pv_name" --for=jsonpath='{.status.phase}'=Released --timeout=2m
"$kubectl" delete pv "$pv_name" --wait=true
"$kubectl" apply -f "$storage_manifest"
"$kubectl" wait pvc/zettide-fuse -n "$namespace" --for=jsonpath='{.status.phase}'=Bound --timeout=2m
cat >"$verifier_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: verifier
  namespace: $namespace
spec:
  restartPolicy: Never
  containers:
    - name: verifier
      image: $workload_local
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - >-
          set -eu; cd /data; sha256sum -c payload.sha256;
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
        claimName: zettide-fuse
        readOnly: true
    - name: status
      emptyDir: {}
EOF
cp "$verifier_manifest" "$log_dir/verifier.yaml"
"$kubectl" apply -f "$verifier_manifest"
"$kubectl" wait pod/verifier -n "$namespace" --for=condition=Ready --timeout=5m
"$kubectl" logs -n "$namespace" verifier >"$log_dir/verifier.log" 2>&1 || true
"$kubectl" delete pod/verifier -n "$namespace" --wait=true
wait_for_no_publication
"$kubectl" delete pvc/zettide-fuse -n "$namespace" --wait=true
"$kubectl" delete pv "$pv_name" --wait=true
"$cli" check "$image" >"$log_dir/post-kubernetes-check.log"
test_succeeded=true
echo "static FUSE CSI kind integration succeeded"
