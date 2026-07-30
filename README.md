# zettide-control

Replicated metadata control plane for Zettide.

The service manages virtual Pools, durable Data Node registrations, and durable
local Member bindings. A Pool is a global namespace for Volumes. Node
registration records stable identity, cluster binding, endpoints, failure
domain, capabilities, and protocol version. Member registration binds a native
media identity and local set to a control Pool and Node, with immutable slot and
allocation geometry. Leader-local heartbeats currently observe Node
incarnation/sequence, Member presence, and optional extent capacity. Volumes,
Extents, replica placement, and DataService reconciliation are separate layers.

Pool, Node, and Member mutations are committed and applied through Raft before
an RPC reports success. Reads use Raft ReadIndex rather than serving
follower-local state.

`ReportHeartbeat` and `GetHeartbeat` use ReadIndex callbacks to serialize
durable binding checks and observation access on the Raft driver thread.
Observations never enter the WAL or snapshots and are cleared on every leader
transition or snapshot restore. Nodes must report again to a new leader. The
recommended interval is one second and observations become stale after five
seconds.

The state machine stores canonical commands and responses for idempotent
request replay. Request IDs share one namespace across resource kinds, so
cross-kind reuse returns a request conflict. Snapshots are deterministic
protobuf messages and are validated before atomically replacing live state.
The current format limits a cluster to 25,000 Pools, 10,000 Nodes, 10,000
Members, and 50,000 retained request records so committed input cannot grow
memory and snapshots without bound. Snapshot format v4 reads v2 Pool-only, v3
Pool/Node, and v4 Pool/Node/Member snapshots.
The heartbeat store separately limits itself to 10,000 Nodes, 10,000 Member
observations, and 256 Members per report.

The services require Raft quorum checking, disabled proposal forwarding, and
finite proposal and ReadIndex timeouts. Their allocator must be thread-safe.
`PoolRpc` adapts Pool, Node, Member, and Heartbeat operations to grpc-lite
retained calls.
Response command failures use grpc-lite's allocation-free call abort path.
The daemon uses persistent WAL storage and grpc-lite streams between statically
configured voters. Existing storage is automatically opened in restart mode.
Shutdown order is: stop RPC admission, stop and wait for the gRPC server, stop
Raft, join the driver and drain callbacks, verify `PoolRpc` is idle, then
deinitialize the services.

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
