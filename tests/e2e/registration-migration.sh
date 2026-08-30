#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
compose_file="$repo_root/tests/e2e/docker-compose.yml"
compose=(docker compose -f "$compose_file")

cleanup() {
    "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
"${compose[@]}" up -d --build controller bootstrap
"${compose[@]}" run --rm --no-deps \
    --entrypoint /usr/local/bin/zettide-e2e-registration-migration bootstrap prepare
"${compose[@]}" up -d --build data-node-1 data-node-2 data-node-3

for service in data-node-1 data-node-2 data-node-3; do
    container_id=$("${compose[@]}" ps -q "$service")
    ready=false
    for _ in {1..90}; do
        if [[ $(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true) == healthy ]]; then
            ready=true
            break
        fi
        sleep 1
    done
    [[ $ready == true ]] || {
        "${compose[@]}" logs "$service" >&2
        echo "$service did not enroll through the actual daemon registration path" >&2
        exit 1
    }
done

"${compose[@]}" run --rm --no-deps \
    --entrypoint /usr/local/bin/zettide-e2e-registration-migration bootstrap verify

# A different seed must not replace the controller-pinned generation-1 key.
"${compose[@]}" stop data-node-1 >/dev/null
"${compose[@]}" rm -f data-node-1 >/dev/null
set +e
conflict_output=$(timeout 75 "${compose[@]}" run --rm --no-deps \
    -e ZETTIDE_REPLICA_SIGNING_SEED=0404040404040404040404040404040404040404040404040404040404040404 \
    data-node-1 2>&1)
conflict_status=$?
set -e
if [[ $conflict_status -eq 0 ]]; then
    printf '%s\n' "$conflict_output" >&2
    echo "conflicting signing seed unexpectedly started" >&2
    exit 1
fi
# The entrypoint also owns tgtd, so timeout(1) may terminate the wrapper while
# it is cleaning up even after the data-node has exhausted registration. The
# repeated fail-closed reason is the required evidence; success is forbidden.
grep -Fq 'RegisteredNodeMismatch' <<<"$conflict_output" || {
    printf '%s\n' "$conflict_output" >&2
    echo "conflicting signing seed failed for an unexpected reason" >&2
    exit 1
}
"${compose[@]}" run --rm --no-deps \
    --entrypoint /usr/local/bin/zettide-e2e-registration-migration bootstrap verify
echo "conflicting signing seed startup rejection: ok (pinned key unchanged)"
