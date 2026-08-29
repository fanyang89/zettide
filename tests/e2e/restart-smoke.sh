#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_NODE_IDS:=0198f54d-5c2a-7000-8000-000000000011 0198f54d-5c2a-7000-8000-000000000021 0198f54d-5c2a-7000-8000-000000000031}"
: "${ZETTIDE_MEMBER_CAPACITY:=67108864}"
: "${ZETTIDE_EXTENT_SIZE:=4194304}"

controller_proto=/proto/zettide/controller/v1/controller.proto
state_file=/bootstrap/control-state.json
[[ -s $state_file ]] || {
    echo "initial smoke state is missing: ${state_file}" >&2
    exit 1
}
read -r -a node_ids <<<"$ZETTIDE_NODE_IDS"
pool_id=$(</bootstrap/pool-id)
volume_id=$(jq -er '.volumeId' "$state_file")
previous_write_epoch=$(jq -er '.writeEpoch' "$state_file")
expected_allocated=$((8388608 / ZETTIDE_EXTENT_SIZE))
expected_free=$((ZETTIDE_MEMBER_CAPACITY / ZETTIDE_EXTENT_SIZE - expected_allocated))

members_ready=false
for _ in {1..90}; do
    if members=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
        -d '{"pageSize":100}' "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.MemberService/ListMembers 2>/dev/null) \
        && [[ $(jq -r --arg pool "$pool_id" '[.members[]? | select(.poolId == $pool)] | length' <<<"$members") == "${#node_ids[@]}" ]]; then
        members_ready=true
        break
    fi
    sleep 1
done
[[ $members_ready == true ]] || {
    echo "Members did not recover after process restart" >&2
    exit 1
}

for node_id in "${node_ids[@]}"; do
    member_id=$(jq -er --arg pool "$pool_id" --arg node "$node_id" \
        '.members[]? | select(.poolId == $pool and .nodeId == $node) | .id' <<<"$members")
    previous_incarnation=$(jq -er --arg node "$node_id" '.incarnations[$node]' "$state_file")
    reincarnated=false
    for _ in {1..90}; do
        if heartbeat=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
            -d "$(jq -cn --arg nodeId "$node_id" '{nodeId:$nodeId}')" \
            "$ZETTIDE_CONTROLLER_ENDPOINT" \
            zettide.controller.v1.HeartbeatService/GetHeartbeat 2>/dev/null) \
            && jq -e \
                --arg member "$member_id" \
                --arg free "$expected_free" \
                --arg allocated "$expected_allocated" \
                --arg previous "$previous_incarnation" \
                '.freshness == "HEARTBEAT_FRESHNESS_FRESH" and
                 (.observation.incarnation | tonumber) > ($previous | tonumber) and
                 (.observation.members[]? |
                    .memberId == $member and
                    .capacity.freeExtentCount == $free and
                    .capacity.allocatedExtentCount == $allocated)' \
                >/dev/null <<<"$heartbeat"; then
            reincarnated=true
            break
        fi
        sleep 1
    done
    [[ $reincarnated == true ]] || {
        echo "durable Replica capacity or advanced incarnation was not observed for ${node_id}" >&2
        exit 1
    }
done
echo "three-node process restart and Replica recovery/reconciliation: ok"

failover_ready=false
for _ in {1..180}; do
    if volume=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
        -d "$(jq -cn --arg volumeId "$volume_id" '{volumeId:$volumeId}')" \
        "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.VolumeService/GetVolume 2>/dev/null) \
        && jq -e --arg previous "$previous_write_epoch" \
            '.volume.lifecycleState == "VOLUME_LIFECYCLE_STATE_ACTIVE" and
             .volume.availabilityState == "VOLUME_AVAILABILITY_STATE_HEALTHY" and
             .volume.operationPhase == "VOLUME_OPERATION_PHASE_NONE" and
             (.volume.writeEpoch | tonumber) > ($previous | tonumber)' \
            >/dev/null <<<"$volume"; then
        failover_ready=true
        break
    fi
    sleep 1
done
[[ $failover_ready == true ]] || {
    echo "Volume did not recover through a higher write epoch after restart" >&2
    printf '%s\n' "${volume:-no GetVolume response}" >&2
    exit 1
}
new_write_epoch=$(jq -er '.volume.writeEpoch' <<<"$volume")
echo "restart failover and authority replacement: ok (${previous_write_epoch} -> ${new_write_epoch})"
