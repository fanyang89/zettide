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
Shutdown order is: stop RPC admission, stop and wait for the gRPC server, call
`PoolRpc.shutdown`, join the Raft driver, then deinitialize `PoolRpc` and the
server.

## Development

```sh
zig build test --summary all
```
