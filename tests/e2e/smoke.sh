#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_NODE_ID:=0198f54d-5c2a-7000-8000-000000000002}"
: "${ZETTIDE_MEMBER_CAPACITY:=67108864}"
: "${ZETTIDE_EXTENT_SIZE:=4194304}"
: "${ZETTIDE_ISCSI_PORTAL:=data-node:3260}"
: "${ZETTIDE_ISCSI_TARGET:=iqn.2026-08.io.zettide:e2e}"
: "${ZETTIDE_ISCSI_LUN:=1}"

controller_proto=/proto/zettide/controller/v1/controller.proto
registered=false
for _ in {1..90}; do
    if nodes=$(grpcurl -plaintext -import-path /proto -proto "$controller_proto" \
        -d '{"pageSize":100}' "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.NodeService/ListNodes 2>/dev/null) \
        && jq -e --arg id "$ZETTIDE_NODE_ID" '.nodes[]? | select(.id == $id)' \
            >/dev/null <<<"$nodes"; then
        registered=true
        break
    fi
    sleep 1
done
[[ $registered == true ]] || {
    echo "data-node was not registered with the controller" >&2
    exit 1
}
echo "controller node registration: ok (${ZETTIDE_NODE_ID})"

pool_id=$(</bootstrap/pool-id)
member_registered=false
member_id=""
for _ in {1..90}; do
    if members=$(grpcurl -plaintext -import-path /proto -proto "$controller_proto" \
        -d '{"pageSize":100}' "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.MemberService/ListMembers 2>/dev/null) \
        && member_id=$(jq -er --arg pool "$pool_id" --arg node "$ZETTIDE_NODE_ID" \
            '.members[]? | select(.poolId == $pool and .nodeId == $node) | .id' \
            <<<"$members"); then
        member_registered=true
        break
    fi
    sleep 1
done
[[ $member_registered == true ]] || {
    echo "file Member was not registered with the controller" >&2
    exit 1
}

expected_free=$((ZETTIDE_MEMBER_CAPACITY / ZETTIDE_EXTENT_SIZE))
heartbeat_observed=false
for _ in {1..90}; do
    if heartbeat=$(grpcurl -plaintext -import-path /proto -proto "$controller_proto" \
        -d "$(jq -cn --arg nodeId "$ZETTIDE_NODE_ID" '{nodeId:$nodeId}')" \
        "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.HeartbeatService/GetHeartbeat 2>/dev/null) \
        && jq -e --arg member "$member_id" --arg free "$expected_free" \
            '.freshness == "HEARTBEAT_FRESHNESS_FRESH" and
             (.observation.members[]? |
                .memberId == $member and
                .state == "MEMBER_HEARTBEAT_STATE_PRESENT" and
                .capacity.freeExtentCount == $free)' \
            >/dev/null <<<"$heartbeat"; then
        heartbeat_observed=true
        break
    fi
    sleep 1
done
[[ $heartbeat_observed == true ]] || {
    echo "fresh file-Member capacity heartbeat was not observed" >&2
    exit 1
}
echo "controller Member registration and capacity heartbeat: ok (${pool_id})"

portal_url="iscsi://${ZETTIDE_ISCSI_PORTAL}"
lun_url="${portal_url}/${ZETTIDE_ISCSI_TARGET}/${ZETTIDE_ISCSI_LUN}"
discovered=false
for _ in {1..30}; do
    if discovery=$(iscsi-ls --show-luns "$portal_url" 2>/dev/null) \
        && grep -Fq "$ZETTIDE_ISCSI_TARGET" <<<"$discovery"; then
        discovered=true
        break
    fi
    sleep 1
done
[[ $discovered == true ]] || {
    echo "libiscsi could not discover ${ZETTIDE_ISCSI_TARGET}" >&2
    exit 1
}
printf '%s\n' "$discovery"

iscsi-inq "$lun_url"
iscsi-readcapacity16 "$lun_url"
timeout 60 iscsi-md5sum "$lun_url"
echo "libiscsi smoke: ok (${lun_url})"
