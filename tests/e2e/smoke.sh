#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_NODE_ID:=0198f54d-5c2a-7000-8000-000000000002}"
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
echo "controller registration: ok (${ZETTIDE_NODE_ID})"

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
