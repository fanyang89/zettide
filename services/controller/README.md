# zettide-controller

Replicated metadata control plane for Zettide.

The service manages virtual Pools, durable Volume metadata, durable Data Node
registrations, and durable local Member bindings. A Pool is a global namespace
for Volumes. Node
registration records stable identity, cluster binding, management/NVMf/internal
Replica endpoints, failure domain, capabilities, protocol version, and an
optional generation-1 Ed25519 signing public key. Replica endpoints and signing
keys are snapshot- and restart-stable. Either legacy empty value may be filled
once by a new identity-matched Raft request, including a joint fill; nonempty key
replacement is rejected. The controller derives key IDs from strict canonical,
non-identity, expected-subgroup public keys and does not accept caller-selected
key IDs. Rotation and revocation are not implemented. Member registration binds a native
media identity and local set to a controller-managed Pool and Node, with immutable slot and
allocation geometry. Leader-local heartbeats currently observe Node
incarnation/sequence, Member presence, and optional extent capacity. Volume
creation first commits a `PROVISIONING` metadata intent with fixed 3/2/1
replication parameters. Leader reconciliation then reserves three placements and
extents, ensures file-backed Replicas, configures the same immutable canonical
three-Member write-participant set on all of them, including the canonical
Member-to-Node-to-key trust set derived from active topology. Before every
authority/readiness path it also provisions identical canonical three-route
coordinator metadata, including each pinned Replica endpoint; endpoints remain
routing metadata outside signed participant identity. It then drives the current
fence/recovery/authority lifecycle to `ACTIVE`. Keyless or inconsistent
topology fails closed before participant readiness. The daemon enrolls its
owner-only generation-1 signing seed and ReplicaTransport exchanges signed
evidence verified against these pinned identities. The controller stages the
same canonical authority on both remote witnesses first and the primary last.
Every target is freshly identified and must echo its exact process boot ID;
witnesses retain the primary holder identity in signed transcripts while enforcing
their own process-local fail-closed lease windows. A not-yet-ready candidate may
be safely restaged after restart, but an already-ready lease is never extended this
way. All witness ready acknowledgements are required before controller readiness is published. Internal coordinator
fanout can consequently commit to local plus one remote, but publication,
client-facing quorum success, replacement recovery, read/repair, and attachments
remain separate layers.

`zig build test-controller` includes the controller-state mixed-rollout gate: it
restores persisted keyless Node records with an activated selected topology,
proves readiness remains blocked as generation-1 keys are filled one Node at a
time, then converges only after all three are pinned and rejects a replacement
key. `tests/e2e/registration-migration.sh` separately exercises the real
controller RPC plus data-node daemon registration path for legacy dedup replay,
endpoint-first, key-first, atomic exact state, and conflicting-seed rejection.

Pool, Volume, Node, and Member mutations are committed and applied through Raft
before an RPC reports success. Reads use Raft ReadIndex rather than serving
follower-local state.

## Logical Pool and Volume CRUD

These are controller metadata APIs, not physical Pool provisioning or a promise
that Volume data I/O is ready. They are available over gRPC and `zettidectl`.

| Resource | Methods | Update scope |
| --- | --- | --- |
| Pool | CreatePool, GetPool, ListPools, UpdatePool, DeletePool | Description only |
| Volume | CreateVolume, GetVolume, ListVolumes, UpdateVolume, DeleteVolume | Description only |

Names, IDs, Volume size, and Pool binding are immutable. Update replaces the full
description; an empty description clears it. Volume descriptions can be updated
while `ACTIVE`, or while `PROVISIONING` before placement starts. A metadata-only
Volume can therefore complete CRUD without any registered data nodes.

Update and delete require the latest `resource_version` returned by Get/List.
Version mismatch returns `FAILED_PRECONDITION`; missing/deleted resources return
`NOT_FOUND`. Every mutation uses a globally unique `request_id`. Reuse the exact
request after a timeout: both successful and rejected business results are durable.
After fixing a version conflict or nonempty-Pool failure, use a **new** request ID.

`DeletePool` rejects Pools with any live Volume (including deleting Volumes) or
registered Member. Member unregistration is not implemented, so a Pool with
registered Members cannot currently be deleted. Volume tombstones do not block
Pool deletion. Pool tombstones retain the last description, creation identity,
`resource_version`, and `deleted_revision`; they are hidden from Get/List.
Deleted names may be reused, but deleted IDs cannot be reused.

`DeleteVolume` immediately removes metadata when there are no Replica/Attachment
dependencies, retaining a durable tombstone. Otherwise it accepts asynchronous
deletion (`deletion_pending = true`) and reconciliation removes dependencies;
Get/List may still show the deleting Volume until finalization.

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
The current format limits a cluster to 25,000 Pools including tombstones, 25,000 live Volumes,
25,000 Volume tombstones, 75,000 Replica placements, 75,000 Replica
allocations, 25,000 Volume attachments, 10,000 Nodes, 10,000 Members, and
50,000 retained request records so committed input cannot grow memory and
snapshots without bound. Snapshot format v13 reads v2–v12 snapshots and preserves
Pool mutation history/tombstones. Legacy Pools receive their creation revision
as `resource_version`. Command format v10 reads v1–v9 commands; legacy Volume
update commands retain their original active-only behavior during WAL replay.
All controller voters must be upgraded together before enabling v10 writes.
Older binaries cannot restore v13 snapshots; do not downgrade against an upgraded
data directory. Snapshot restore replays Pool history to verify final values,
versions, tombstones, name reuse, and historical deletion dependencies before
atomically replacing live state.
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

## Range leases

`RangeLeaseService` supports shared-read/exclusive-write Volume intervals with
Acquire, Renew, Revoke, CompleteRevoke, Get, and List. Mutations commit through
Raft; reads use ReadIndex. Revoke is two-phase: REVOKING still blocks conflicts
until the trusted holder acknowledges drained I/O. Active/revoking leases block
Volume deletion. Lease history and its canonical view digest are snapshot-stable.

See [range lease contract](../../docs/range-leases.md) for the holder session,
local deadlines, RPC semantics, recovery, security, and current integration
limits. In particular, lost holders are not automatically reclaimed, and the
new gate is not yet mandatory on every existing payload path.

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
listen address. The production daemon creates its DataService RPC client and
runs leader-only reconciliation by default; tune it with
`--reconcile-interval-ms` (default `1000`) and
`--data-service-timeout-ms` (default `5000`). `SIGINT` and `SIGTERM` initiate
graceful RPC, reconciliation, and Raft shutdown.

## Development

```sh
zig build
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
```
