#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
mode=${1:?usage: registration-migration-smoke.sh prepare|verify}
controller_proto=/proto/zettide/controller/v1/controller.proto
# Controller wire IDs use the same little-endian UUID byte representation as
# the Zig services; this is UUID 0198f54d-5c2a-7000-8000-000000000001.
cluster_id=AQAAAAAAAIAAcCpcTfWYAQ==

node_ids=(
    0198f54d-5c2a-7000-8000-000000000011
    0198f54d-5c2a-7000-8000-000000000021
    0198f54d-5c2a-7000-8000-000000000031
)
request_ids=(
    0198f54d-5c2a-7000-8000-000000000012
    0198f54d-5c2a-7000-8000-000000000022
    0198f54d-5c2a-7000-8000-000000000032
)
control_endpoints=(172.30.0.11:7001 172.30.0.12:7001 172.30.0.13:7001)
replica_endpoints=(172.30.0.11:7443 172.30.0.12:7443 172.30.0.13:7443)
nvmf_endpoints=(
    iscsi://data-node-1:3260/iqn.2026-08.io.zettide:e2e-1/1
    iscsi://data-node-2:3260/iqn.2026-08.io.zettide:e2e-2/1
    iscsi://data-node-3:3260/iqn.2026-08.io.zettide:e2e-3/1
)
failure_domains=(rack-a rack-b rack-c)
signing_keys=(
    iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=
    gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q=
    7UkoxijRwsbq6QM4kFmVYSlZJzpcY/k2NsFGFKyHN9E=
)
endpoint_request_ids=(
    ab50c2dd-4fcf-7d44-b058-6e2b6370b027
    598fcf14-ce27-7804-a6fa-6fa18aa8de41
    092b7579-d4b5-7bee-b44a-f0d8d70e2feb
)
signing_request_ids=(
    88890e20-e399-783f-ba44-7d9afe43facf
    4ed38b44-a38f-734e-b0ca-3f727123b676
    eb945001-1782-7ae6-bc95-126c57623c58
)

register_node() {
    local index=$1 request_id=$2 replica_endpoint=${3-} signing_key=${4-}
    local payload
    payload=$(jq -cn \
        --arg requestId "$request_id" \
        --arg nodeId "${node_ids[$index]}" \
        --arg clusterId "$cluster_id" \
        --arg controlEndpoint "${control_endpoints[$index]}" \
        --arg nvmfEndpoint "${nvmf_endpoints[$index]}" \
        --arg failureDomain "${failure_domains[$index]}" \
        --arg replicaEndpoint "$replica_endpoint" \
        --arg signingPublicKey "$signing_key" \
        '{requestId:$requestId,nodeId:$nodeId,clusterId:$clusterId,
          controlEndpoint:$controlEndpoint,nvmfEndpoint:$nvmfEndpoint,
          failureDomain:$failureDomain,capabilityBits:"1",protocolVersion:1,
          replicaEndpoint:$replicaEndpoint,signingPublicKey:$signingPublicKey}')
    local response
    for _ in {1..90}; do
        if response=$(grpcurl -max-time 5 -plaintext -import-path /proto -proto "$controller_proto" \
            -d "$payload" "$ZETTIDE_CONTROLLER_ENDPOINT" \
            zettide.controller.v1.NodeService/RegisterNode 2>/dev/null); then
            printf '%s\n' "$response"
            return
        fi
        sleep 1
    done
    echo "RegisterNode did not succeed before the migration deadline" >&2
    return 1
}

get_node() {
    local index=$1
    grpcurl -max-time 5 -plaintext -import-path /proto -proto "$controller_proto" \
        -d "$(jq -cn --arg nodeId "${node_ids[$index]}" '{nodeId:$nodeId}')" \
        "$ZETTIDE_CONTROLLER_ENDPOINT" zettide.controller.v1.NodeService/GetNode
}

case $mode in
prepare)
    # Node 1 is legacy keyless with a separately filled endpoint. Replaying the
    # original request later returns its stale keyless dedup response.
    register_node 0 "${request_ids[0]}" >/dev/null
    register_node 0 "${endpoint_request_ids[0]}" "${replica_endpoints[0]}" >/dev/null

    # Node 2 exercises signing-key-first migration.
    register_node 1 "${request_ids[1]}" >/dev/null
    register_node 1 "${signing_request_ids[1]}" "" "${signing_keys[1]}" >/dev/null

    # Node 3 models an earlier atomic rollout using the original request ID.
    register_node 2 "${request_ids[2]}" "${replica_endpoints[2]}" "${signing_keys[2]}" >/dev/null
    echo "registration migration prestate: ok (endpoint-first, key-first, atomic exact)"
    ;;
verify)
    for index in 0 1 2; do
        current=$(get_node "$index")
        jq -e \
            --arg endpoint "${replica_endpoints[$index]}" \
            --arg key "${signing_keys[$index]}" \
            '.node.replicaEndpoint == $endpoint and .node.signingPublicKey == $key' \
            >/dev/null <<<"$current"
    done

    stale=$(register_node 0 "${request_ids[0]}")
    jq -e '(.node.replicaEndpoint // "") == "" and (.node.signingPublicKey // "") == ""' \
        >/dev/null <<<"$stale"
    current=$(get_node 0)
    jq -e \
        --arg endpoint "${replica_endpoints[0]}" \
        --arg key "${signing_keys[0]}" \
        '.node.replicaEndpoint == $endpoint and .node.signingPublicKey == $key' \
        >/dev/null <<<"$current"
    echo "actual daemon registration migration: ok (fresh GetNode overrides stale dedup response)"
    ;;
*)
    echo "unknown registration migration mode: $mode" >&2
    exit 2
    ;;
esac
