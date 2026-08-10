#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$project_root/.zig-cache/official"
server_port=${HTTP2_SERVER_PORT:-$((30000 + $$ % 10000))}
server_pid=

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$work_dir"
(cd "$project_root" && zig build)

"$project_root/zig-out/bin/grpc-lite-interop-server" \
  --port="$server_port" --use_tls=false >"$work_dir/http2-server.log" 2>&1 &
server_pid=$!

for _ in {1..100}; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$server_port") 2>/dev/null; then
    exec 3>&-
    exec 3<&-
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$work_dir/http2-server.log" >&2
    exit 1
  fi
  sleep 0.05
done

printf '%s\n' '[ RUN  ] official gRPC HTTP/2 framing suite'
output_file="$work_dir/http2-framing.log"
(cd "$project_root/tests/official" && \
  go test -mod=readonly -count=1 -v github.com/grpc/grpc/tools/http2_interop --args \
    -server_host=127.0.0.1 \
    -server_port="$server_port" \
    -use_tls=false \
    -test_case=framing) 2>&1 | tee "$output_file"
python3 "$project_root/tests/official/validate_http2_report.py" "$output_file"
printf '%s\n' '[ COMPLETE ] official gRPC HTTP/2 framing report'
