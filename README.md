# zettide-control

Replicated metadata control plane for Zettide.

The initial service manages virtual Pools. A Pool is a global namespace for
Volumes; Volumes, Extents, replica placement, and DataService reconciliation
are separate metadata layers and are not part of the first milestone.

Pool mutations are committed and applied through Raft before an RPC reports
success. Reads use Raft ReadIndex rather than serving follower-local state.

The state machine stores canonical commands and responses for idempotent
request replay. Snapshots are deterministic protobuf messages and are
validated before atomically replacing live state. The initial format limits a
cluster to 25,000 Pools and 50,000 retained request records so committed input
cannot grow memory and snapshots without bound.

`PoolService` requires Raft quorum checking, disabled proposal forwarding, and
finite proposal and ReadIndex timeouts. Its allocator must be thread-safe.
`PoolRpc` adapts the asynchronous operations to grpc-lite retained calls.
Response command failures use grpc-lite's allocation-free call abort path.
The daemon uses persistent WAL storage and grpc-lite streams between statically
configured voters. Existing storage is automatically opened in restart mode.
Shutdown order is: stop RPC admission, stop and wait for the gRPC server, call
`PoolRpc.shutdown`, join the Raft driver, then deinitialize `PoolRpc` and the
server.

## Running

Each voter needs a stable node ID, cluster UUID, Raft address, management
address, and data directory. Every voter must receive the same initial peer
set. For example, node 1 of a three-voter cluster can be started with:

```sh
zig build run -- \
  --node-id 1 \
  --cluster-id 0198f54d-5c2a-7000-8000-000000000001 \
  --management-listen 127.0.0.1:8001 \
  --raft-listen 127.0.0.1:9001 \
  --data-dir ./data/node-1 \
  --peer 1=127.0.0.1:9001 \
  --peer 2=127.0.0.1:9002 \
  --peer 3=127.0.0.1:9003
```

Use `--raft-advertise` when the address visible to peers differs from the local
listen address. `SIGINT` and `SIGTERM` initiate graceful RPC and Raft shutdown.

## Development

```sh
zig build
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
```
