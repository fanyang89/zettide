# zettide-controller

Replicated metadata control plane for Zettide.

The service manages virtual Pools, durable Volume metadata, durable Data Node
registrations, and durable local Member bindings. A Pool is a global namespace
for Volumes. Node
registration records stable identity, cluster binding, endpoints, failure
domain, capabilities, and protocol version. Member registration binds a native
media identity and local set to a controller-managed Pool and Node, with immutable slot and
allocation geometry. Leader-local heartbeats currently observe Node
incarnation/sequence, Member presence, and optional extent capacity. Volume
creation currently commits a `PROVISIONING` metadata intent with fixed 3/2/1
replication parameters; it does not select placement, reserve extents, publish a
device, or wait for data-plane readiness. Replica placement, extent allocation,
attachments, and DataService reconciliation remain separate layers.

Pool, Volume, Node, and Member mutations are committed and applied through Raft
before an RPC reports success. Reads use Raft ReadIndex rather than serving
follower-local state.

`DeleteVolume` requires the current resource version and succeeds only while the
Volume has no Replica or Attachment dependencies. It atomically removes the live
metadata and retains a durable tombstone so the Volume ID cannot be reused.
Deleted names may be reused; `GetVolume` returns `NOT_FOUND` after deletion.

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
The current format limits a cluster to 25,000 Pools, 25,000 live Volumes,
25,000 Volume tombstones, 75,000 Replica placements, 75,000 Replica
allocations, 25,000 Volume attachments, 10,000 Nodes, 10,000 Members, and
50,000 retained request records so committed input cannot grow memory and
snapshots without bound. Snapshot format v5 reads v2 Pool-only, v3 Pool/Node,
v4 Pool/Node/Member, and v5 Volume snapshots. Command format v2 reads legacy v1
commands. Activating v2 requires a coordinated upgrade because old binaries do
not understand Volume commands or v2 envelopes.
The heartbeat store separately limits itself to 10,000 Nodes, 10,000 Member
observations, and 256 Members per report.

The services require Raft quorum checking, disabled proposal forwarding, and
finite proposal and ReadIndex timeouts. Their allocator must be thread-safe.
`PoolRpc` adapts Pool, Volume, Node, Member, and Heartbeat operations to
grpc-lite retained calls.
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
