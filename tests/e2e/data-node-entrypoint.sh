#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_DATA_NODE_LISTEN:=0.0.0.0:7001}"
: "${ZETTIDE_DATA_NODE_ADVERTISE:=data-node:7001}"
: "${ZETTIDE_CLUSTER_ID:=0198f54d-5c2a-7000-8000-000000000001}"
: "${ZETTIDE_NODE_ID:=0198f54d-5c2a-7000-8000-000000000002}"
: "${ZETTIDE_REQUEST_ID:=0198f54d-5c2a-7000-8000-000000000003}"
: "${ZETTIDE_ISCSI_TARGET:=iqn.2026-08.io.zettide:e2e}"
: "${ZETTIDE_ISCSI_PORT:=3260}"
: "${ZETTIDE_ISCSI_LUN:=1}"
: "${ZETTIDE_ISCSI_SIZE:=64M}"
: "${ZETTIDE_FAILURE_DOMAIN:=local/docker}"

backing_file=/var/lib/zettide-data-node/lun.img
mkdir -p "$(dirname "$backing_file")"
truncate -s "$ZETTIDE_ISCSI_SIZE" "$backing_file"

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
    --iscsi-endpoint "iscsi://data-node:${ZETTIDE_ISCSI_PORT}/${ZETTIDE_ISCSI_TARGET}/${ZETTIDE_ISCSI_LUN}" \
    --failure-domain "$ZETTIDE_FAILURE_DOMAIN" &
data_node_pid=$!

wait -n "$tgtd_pid" "$data_node_pid"
exit 1
