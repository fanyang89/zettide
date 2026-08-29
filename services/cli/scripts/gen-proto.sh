#!/bin/sh
set -eu

cli_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$cli_root/../.." && pwd)
module=github.com/fanyang89/zettide/cli
package="$module/internal/gen/controller/v1"
controller_proto=services/controller/proto/zettide/controller/v1/controller.proto
data_service_proto=libs/data-service-contracts/proto/zettide/controller/v1/data_service.proto

protoc -I "$repo_root" \
  --go_out="$cli_root" \
  --go_opt="module=$module" \
  --go_opt="M$controller_proto=$package" \
  --go_opt="M$data_service_proto=$package" \
  --go-grpc_out="$cli_root" \
  --go-grpc_opt="module=$module" \
  --go-grpc_opt="M$controller_proto=$package" \
  --go-grpc_opt="M$data_service_proto=$package" \
  "$repo_root/$controller_proto" \
  "$repo_root/$data_service_proto"
