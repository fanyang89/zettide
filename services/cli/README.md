# zettidectl

`zettidectl` is the Go gRPC administration client for the Zettide controller and
data-node services.

The first release intentionally exposes controller management RPCs and read-only
data-node diagnostics:

- controller: Pool create/get/update/list/delete;
- controller: Node register/get/list;
- controller: Member register/get/list;
- controller: Volume create/get/update/list/delete;
- controller: Heartbeat get;
- data-node: holder identify and primary inspect.

Replica allocation, fencing, recovery, and primary mutation RPCs remain internal
to controller reconciliation and are not exposed by this CLI.

## Build and check

```sh
cd services/cli
mise trust
mise install
mise run check
mkdir -p bin
go build -o bin/zettidectl ./cmd/zettidectl
```

Generated Go protobuf and gRPC sources are committed under
`internal/gen/controller/v1`. Regenerate them after either source protocol
changes:

```sh
cd services/cli
mise run generate
```

The generator consumes:

- `services/controller/proto/zettide/controller/v1/controller.proto`
- `libs/data-service-contracts/proto/zettide/controller/v1/data_service.proto`

## Connection and output

Global flags must precede the target name:

```text
zettidectl [global flags] <controller|data-node> <resource> <command> [flags]
```

`--endpoint host:port` is required unless `ZETTIDE_ENDPOINT` is set. Connections
use plaintext by default for local development. Supplying `--tls-ca FILE`
enables TLS with an explicit PEM trust root; `--tls-server-name NAME` overrides
certificate hostname verification when the dial target is not the certificate
name.

The default output is a human-readable table. Use `--output json` for stable
protobuf JSON field names and enum names.

## Examples

```sh
# List pools over plaintext.
zettidectl --endpoint 127.0.0.1:50051 controller pool list

# Create a volume. Mutations generate a request ID unless one is supplied.
zettidectl --endpoint 127.0.0.1:50051 controller volume create \
  --pool-id 0198f54d-5c2a-7000-8000-000000000001 \
  --name database --size-bytes 10737418240

# Use JSON over TLS.
zettidectl --endpoint controller.storage.example:443 \
  --tls-ca /etc/zettide/controller-ca.pem --output json \
  controller node list

# Inspect a data-node's boot holder identity.
zettidectl --endpoint 10.0.0.12:50052 data-node holder identify
```

Opaque page tokens are accepted and printed as base64. Binary IDs accept either
hexadecimal bytes or UUID text. `data-node primary inspect` requires the complete
authority binding because the DataService validates the binding before returning
its diagnostic state; run the command with `-h` to list all required fields.

## Logical metadata CRUD

Pool and Volume updates replace only the description (empty clears it); names,
IDs, size, and Pool binding cannot be changed. Get/List exposes
`resource_version`; pass that value to update/delete. Use an explicit request ID
and reuse it with identical fields after an uncertain result. A corrected request
following a version conflict or dependency rejection needs a new request ID.

```sh
zettidectl --endpoint 127.0.0.1:8001 controller pool create \
  --name logical --request-id pool-create-1
zettidectl --endpoint 127.0.0.1:8001 controller pool get --name logical
# Substitute the returned ID and resource_version.
zettidectl --endpoint 127.0.0.1:8001 controller pool update \
  --pool-id "$POOL_ID" --expected-resource-version "$POOL_VERSION" \
  --description "Application volumes" --request-id pool-update-1
zettidectl --endpoint 127.0.0.1:8001 controller volume create \
  --pool-id "$POOL_ID" --name database --size-bytes 1048576 \
  --request-id volume-create-1
zettidectl --endpoint 127.0.0.1:8001 controller volume get --volume-id "$VOLUME_ID"
zettidectl --endpoint 127.0.0.1:8001 controller volume update \
  --volume-id "$VOLUME_ID" --expected-resource-version "$VOLUME_VERSION" \
  --description "Database metadata" --request-id volume-update-1
# Refresh versions after updates before deleting.
zettidectl --endpoint 127.0.0.1:8001 controller volume delete \
  --volume-id "$VOLUME_ID" --expected-resource-version "$LATEST_VOLUME_VERSION" \
  --request-id volume-delete-1
zettidectl --endpoint 127.0.0.1:8001 controller pool delete \
  --pool-id "$POOL_ID" --expected-resource-version "$LATEST_POOL_VERSION" \
  --request-id pool-delete-1
```

A Pool cannot be deleted while it has live Volumes or registered Members.
Volume deletion may be asynchronous if Replica/Attachment dependencies exist;
wait for `GetVolume` to return `NOT_FOUND` before deleting its Pool. No data nodes
are needed for pure metadata CRUD; `PROVISIONING` does not mean data I/O is ready.
