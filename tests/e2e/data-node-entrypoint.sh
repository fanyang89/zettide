#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_DATA_NODE_LISTEN:=0.0.0.0:7001}"
: "${ZETTIDE_DATA_NODE_ADVERTISE:=data-node-1:7001}"
: "${ZETTIDE_DATA_NODE_HOST:=data-node-1}"
: "${ZETTIDE_CLUSTER_ID:=0198f54d-5c2a-7000-8000-000000000001}"
: "${ZETTIDE_NODE_ID:=0198f54d-5c2a-7000-8000-000000000002}"
: "${ZETTIDE_REQUEST_ID:=0198f54d-5c2a-7000-8000-000000000003}"
: "${ZETTIDE_POOL_ID_FILE:=/bootstrap/pool-id}"
: "${ZETTIDE_MEMBER_ID:=0198f54d-5c2a-7000-8000-000000000004}"
: "${ZETTIDE_MEMBER_METADATA_CAPACITY:=1048576}"
: "${ZETTIDE_MEMBER_CAPACITY:=67108864}"
: "${ZETTIDE_EXTENT_SIZE:=4194304}"
: "${ZETTIDE_ISCSI_TARGET:=iqn.2026-08.io.zettide:e2e}"
: "${ZETTIDE_ISCSI_PORT:=3260}"
: "${ZETTIDE_ISCSI_LUN:=1}"
: "${ZETTIDE_ISCSI_SIZE:=64M}"
: "${ZETTIDE_FAILURE_DOMAIN:=local/docker}"

backing_file=/var/lib/zettide-data-node/lun.img
member_file=/var/lib/zettide-data-node/member.img
state_dir=/var/lib/zettide-data-node/control
pool_id=$(<"$ZETTIDE_POOL_ID_FILE")
mkdir -p "$(dirname "$backing_file")" "$state_dir"

ensure_geometry() {
    local path=$1
    local expected_size=$2
    if [[ ! -e $path ]]; then
        truncate -s "$expected_size" "$path"
        return
    fi
    local actual_size
    actual_size=$(stat -c '%s' "$path")
    [[ $actual_size == "$expected_size" ]] || {
        echo "persisted file geometry mismatch: ${path}: expected ${expected_size}, found ${actual_size}" >&2
        exit 1
    }
}

ensure_geometry "$backing_file" "$(numfmt --from=iec "$ZETTIDE_ISCSI_SIZE")"
ensure_geometry "$member_file" "$ZETTIDE_MEMBER_CAPACITY"

tgtd --foreground --iscsi "portal=0.0.0.0:${ZETTIDE_ISCSI_PORT}" &
tgtd_pid=$!
data_node_pid=""

cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $data_node_pid ]]; then
        kill -TERM "$data_node_pid" 2>/dev/null
        wait "$data_node_pid" 2>/dev/null
    fi
    kill -TERM "$tgtd_pid" 2>/dev/null
    wait "$tgtd_pid" 2>/dev/null
    exit "$result"
}
trap cleanup EXIT INT TERM

for _ in {1..100}; do
    tgtadm --lld iscsi --op show --mode target >/dev/null 2>&1 && break
    kill -0 "$tgtd_pid"
    sleep 0.1
done
tgtadm --lld iscsi --op show --mode target >/dev/null 2>&1

tgtadm --lld iscsi --op new --mode target --tid 1 --targetname "$ZETTIDE_ISCSI_TARGET"
tgtadm --lld iscsi --op new --mode logicalunit --tid 1 --lun "$ZETTIDE_ISCSI_LUN" \
    --backing-store "$backing_file"
tgtadm --lld iscsi --op bind --mode target --tid 1 --initiator-address ALL

/usr/local/bin/zettide-data-node \
    --listen "$ZETTIDE_DATA_NODE_LISTEN" \
    --advertise "$ZETTIDE_DATA_NODE_ADVERTISE" \
    --controller "$ZETTIDE_CONTROLLER_ENDPOINT" \
    --request-id "$ZETTIDE_REQUEST_ID" \
    --node-id "$ZETTIDE_NODE_ID" \
    --cluster-id "$ZETTIDE_CLUSTER_ID" \
    --iscsi-endpoint "iscsi://${ZETTIDE_DATA_NODE_HOST}:${ZETTIDE_ISCSI_PORT}/${ZETTIDE_ISCSI_TARGET}/${ZETTIDE_ISCSI_LUN}" \
    --failure-domain "$ZETTIDE_FAILURE_DOMAIN" \
    --state-dir "$state_dir" \
    --member-file "$member_file" \
    --member-id "$ZETTIDE_MEMBER_ID" \
    --pool-id "$pool_id" \
    --member-metadata-capacity "$ZETTIDE_MEMBER_METADATA_CAPACITY" \
    --member-capacity "$ZETTIDE_MEMBER_CAPACITY" \
    --extent-size "$ZETTIDE_EXTENT_SIZE" &
data_node_pid=$!

wait -n "$tgtd_pid" "$data_node_pid"
exit 1
