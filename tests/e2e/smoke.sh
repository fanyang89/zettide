#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_NODE_IDS:=0198f54d-5c2a-7000-8000-000000000011 0198f54d-5c2a-7000-8000-000000000021 0198f54d-5c2a-7000-8000-000000000031}"
: "${ZETTIDE_MEMBER_CAPACITY:=67108864}"
: "${ZETTIDE_EXTENT_SIZE:=4194304}"
: "${ZETTIDE_ISCSI_PORTAL:=data-node-1:3260}"
: "${ZETTIDE_ISCSI_TARGET:=iqn.2026-08.io.zettide:e2e-1}"
: "${ZETTIDE_ISCSI_LUN:=1}"
: "${ZETTIDE_VOLUME_REQUEST_ID:=0198f54d-5c2a-7000-8000-000000000040}"

controller_proto=/proto/zettide/controller/v1/controller.proto
read -r -a node_ids <<<"$ZETTIDE_NODE_IDS"

registered=false
for _ in {1..90}; do
    if nodes=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
        -d '{"pageSize":100}' "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.NodeService/ListNodes 2>/dev/null); then
        registered_count=$(jq -r --argjson ids "$(printf '%s\n' "${node_ids[@]}" | jq -R . | jq -s .)" \
            '[.nodes[]? | select(.id as $id | $ids | index($id)) | select((.replicaEndpoint // "") | test(":7443$"))] | length' <<<"$nodes")
        replica_endpoint_count=$(jq -r --argjson ids "$(printf '%s\n' "${node_ids[@]}" | jq -R . | jq -s .)" \
            '[.nodes[]? | select(.id as $id | $ids | index($id)) | .replicaEndpoint] | unique | length' <<<"$nodes")
        signing_key_count=$(jq -r --argjson ids "$(printf '%s\n' "${node_ids[@]}" | jq -R . | jq -s .)" \
            '[.nodes[]? | select(.id as $id | $ids | index($id)) | (.signingPublicKey // "") | select(length > 0)] | unique | length' <<<"$nodes")
        [[ $registered_count == "${#node_ids[@]}" &&
           $replica_endpoint_count == "${#node_ids[@]}" &&
           $signing_key_count == "${#node_ids[@]}" ]] && { registered=true; break; }
    fi
    sleep 1
done
[[ $registered == true ]] || {
    echo "three data-nodes were not registered with the controller" >&2
    exit 1
}
echo "controller node registration: ok (${#node_ids[@]} nodes with distinct Replica endpoints and pinned signing keys)"

mapfile -t replica_endpoints < <(jq -r --argjson ids "$(printf '%s\n' "${node_ids[@]}" | jq -R . | jq -s .)" \
    '.nodes[]? | select(.id as $id | $ids | index($id)) | .replicaEndpoint' <<<"$nodes")
for endpoint in "${replica_endpoints[@]}"; do
    for method in Prepare Commit Inspect; do
        if unauthenticated=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto /proto/zettide/controller/v1/data_service.proto \
            -d '{}' "$endpoint" "zettide.controller.v1.ReplicaTransport/${method}" 2>&1); then
            echo "unauthenticated Replica ${method} unexpectedly succeeded at $endpoint" >&2
            exit 1
        fi
        grep -Fq 'Code: Unauthenticated' <<<"$unauthenticated" || {
            echo "Replica listener did not fail closed for unauthenticated ${method} at $endpoint" >&2
            echo "$unauthenticated" >&2
            exit 1
        }
    done
done
echo "Replica listener PREPARE/COMMIT/INSPECT authentication rejection: ok (${#replica_endpoints[@]} nodes)"

pool_id=$(</bootstrap/pool-id)
member_registered=false
for _ in {1..90}; do
    if members=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
        -d '{"pageSize":100}' "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.MemberService/ListMembers 2>/dev/null) \
        && [[ $(jq -r --arg pool "$pool_id" '[.members[]? | select(.poolId == $pool)] | length' <<<"$members") == "${#node_ids[@]}" ]]; then
        member_registered=true
        break
    fi
    sleep 1
done
[[ $member_registered == true ]] || {
    echo "three file Members were not registered with the controller" >&2
    exit 1
}

expected_free=$((ZETTIDE_MEMBER_CAPACITY / ZETTIDE_EXTENT_SIZE))
for node_id in "${node_ids[@]}"; do
    member_id=$(jq -er --arg pool "$pool_id" --arg node "$node_id" \
        '.members[]? | select(.poolId == $pool and .nodeId == $node) | .id' <<<"$members")
    heartbeat_observed=false
    for _ in {1..90}; do
        if heartbeat=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
            -d "$(jq -cn --arg nodeId "$node_id" '{nodeId:$nodeId}')" \
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
        echo "fresh capacity heartbeat was not observed for ${node_id}" >&2
        exit 1
    }
done
echo "controller Member registration and capacity heartbeat: ok (${pool_id})"

create_payload=$(jq -cn \
    --arg requestId "$ZETTIDE_VOLUME_REQUEST_ID" \
    --arg poolId "$pool_id" \
    '{requestId:$requestId,poolId:$poolId,name:"e2e-volume",description:"three-node control-plane E2E",sizeBytes:"8388608"}')
create_response=$(grpcurl -max-time 5 -plaintext -import-path /proto -proto "$controller_proto" \
    -d "$create_payload" "$ZETTIDE_CONTROLLER_ENDPOINT" \
    zettide.controller.v1.VolumeService/CreateVolume)
volume_id=$(jq -er '.volume.id' <<<"$create_response")

volume_active=false
for _ in {1..120}; do
    if volume=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
        -d "$(jq -cn --arg volumeId "$volume_id" '{volumeId:$volumeId}')" \
        "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.VolumeService/GetVolume 2>/dev/null) \
        && jq -e '.volume.lifecycleState == "VOLUME_LIFECYCLE_STATE_ACTIVE" and
                     .volume.availabilityState == "VOLUME_AVAILABILITY_STATE_HEALTHY" and
                     .volume.operationPhase == "VOLUME_OPERATION_PHASE_NONE" and
                     .volume.targetReplicaCount == 3' >/dev/null <<<"$volume"; then
        volume_active=true
        break
    fi
    sleep 1
done
[[ $volume_active == true ]] || {
    echo "Volume did not reach ACTIVE through real DataService reconciliation" >&2
    printf '%s\n' "${volume:-no GetVolume response}" >&2
    exit 1
}
echo "three-node controller ACTIVE/HEALTHY reconciliation: ok (${volume_id}); runtime readiness is covered by the binding-scoped integration gate"

expected_allocated=$((8388608 / ZETTIDE_EXTENT_SIZE))
expected_free_after=$((expected_free - expected_allocated))
incarnations='{}'
signing_keys='{}'
for node_id in "${node_ids[@]}"; do
    signing_key=$(jq -er --arg node "$node_id" '.nodes[]? | select(.id == $node) | .signingPublicKey' <<<"$nodes")
    signing_keys=$(jq -c --arg node "$node_id" --arg key "$signing_key" \
        '. + {($node): $key}' <<<"$signing_keys")
    member_id=$(jq -er --arg pool "$pool_id" --arg node "$node_id" \
        '.members[]? | select(.poolId == $pool and .nodeId == $node) | .id' <<<"$members")
    allocation_observed=false
    for _ in {1..30}; do
        if heartbeat=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
            -d "$(jq -cn --arg nodeId "$node_id" '{nodeId:$nodeId}')" \
            "$ZETTIDE_CONTROLLER_ENDPOINT" \
            zettide.controller.v1.HeartbeatService/GetHeartbeat 2>/dev/null) \
            && jq -e --arg member "$member_id" --arg free "$expected_free_after" --arg allocated "$expected_allocated" \
                '.freshness == "HEARTBEAT_FRESHNESS_FRESH" and
                 (.observation.members[]? |
                    .memberId == $member and
                    .capacity.freeExtentCount == $free and
                    .capacity.allocatedExtentCount == $allocated)' \
                >/dev/null <<<"$heartbeat"; then
            incarnation=$(jq -er '.observation.incarnation' <<<"$heartbeat")
            incarnations=$(jq -c --arg node "$node_id" --arg incarnation "$incarnation" \
                '. + {($node): $incarnation}' <<<"$incarnations")
            allocation_observed=true
            break
        fi
        sleep 1
    done
    [[ $allocation_observed == true ]] || {
        echo "allocated Replica capacity was not observed for ${node_id}" >&2
        exit 1
    }
done
echo "three-node Replica capacity evidence: ok (${expected_allocated} extents each)"

volume=$(grpcurl -max-time 5 -plaintext -import-path /proto -proto "$controller_proto" \
    -d "$(jq -cn --arg volumeId "$volume_id" '{volumeId:$volumeId}')" \
    "$ZETTIDE_CONTROLLER_ENDPOINT" \
    zettide.controller.v1.VolumeService/GetVolume)
jq -e '.volume.lifecycleState == "VOLUME_LIFECYCLE_STATE_ACTIVE" and
           .volume.availabilityState == "VOLUME_AVAILABILITY_STATE_HEALTHY" and
           .volume.operationPhase == "VOLUME_OPERATION_PHASE_NONE"' >/dev/null <<<"$volume" || {
    echo "Volume authority changed while capturing restart baseline" >&2
    exit 1
}
write_epoch=$(jq -er '.volume.writeEpoch' <<<"$volume")
jq -cn \
    --arg volumeId "$volume_id" \
    --arg writeEpoch "$write_epoch" \
    --argjson incarnations "$incarnations" \
    --argjson signingKeys "$signing_keys" \
    '{volumeId:$volumeId,writeEpoch:$writeEpoch,incarnations:$incarnations,signingKeys:$signingKeys}' \
    >/bootstrap/control-state.json.tmp
mv /bootstrap/control-state.json.tmp /bootstrap/control-state.json

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
