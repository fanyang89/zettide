#!/usr/bin/env bash
set -euo pipefail

: "${ZETTIDE_CONTROLLER_ENDPOINT:=controller:8001}"
: "${ZETTIDE_POOL_NAME:=e2e-file-members}"
: "${ZETTIDE_POOL_REQUEST_ID:=0198f54d-5c2a-7000-8000-000000000010}"

controller_proto=/proto/zettide/controller/v1/controller.proto
output_dir=/bootstrap
output_file="${output_dir}/pool-id"
mkdir -p "$output_dir"

payload=$(jq -cn --arg requestId "$ZETTIDE_POOL_REQUEST_ID" \
    --arg name "$ZETTIDE_POOL_NAME" \
    '{requestId:$requestId,name:$name,description:"Docker E2E file-member pool"}')
response=""
for _ in {1..90}; do
    if response=$(grpcurl -max-time 2 -plaintext -import-path /proto -proto "$controller_proto" \
        -d "$payload" "$ZETTIDE_CONTROLLER_ENDPOINT" \
        zettide.controller.v1.PoolService/CreatePool 2>"${output_dir}/bootstrap-error"); then
        break
    fi
    response=""
    sleep 1
done
if [[ -z $response ]]; then
    cat "${output_dir}/bootstrap-error" >&2
    echo "controller did not become writable before bootstrap deadline" >&2
    exit 1
fi
pool_id=$(jq -er '.pool.id' <<<"$response")
rm -f "${output_dir}/bootstrap-error"

temporary="${output_file}.tmp"
printf '%s\n' "$pool_id" >"$temporary"
mv -f "$temporary" "$output_file"
echo "controller pool bootstrap: ok (${pool_id})"
