# zettide-data-service-contracts

Shared data-service API contracts and authority safety model for Zettide.

The package contains no Raft, CLI, transport implementation, or physical
storage backend dependencies. It owns the wire-neutral Replica/authority models,
the protobuf contract for the separately hosted internal Replica RPC service,
and the
idempotent Replica and fence operation engines and their checksummed,
fsync-backed journals. Replica journal reopen validates complete operation
history—not only bytes and CRC—including prepare/complete pairing, allocation
identity, monotonic placement generations, and permanent extent quarantine.
Backend implementations must return a stable, nonzero identity digest for every
active Replica. Reopen validation indexes operation, allocation, and placement
identity and sorts Member intervals, keeping maximum-size journal startup
bounded rather than performing pairwise history scans.

`write_service` adds the backend-neutral local participant for the future
internal Replica protocol. It durably stages payload bytes, accepts only a
canonical two-Member prepare certificate, persists that decision before applying
and synchronizing the Replica extent, and can finish a decided write after
restart without reviving an expired lease. Certified replay carries its original
authority into the fencing gate. File-backed participants persist an immutable
Replica/canonical-Member genesis binding before the first PREPARE. Their atomic
snapshot remains a development baseline, not the final streaming journal or
network transport. Data-node composition requires an explicitly configured
participant binding before PREPARE/COMMIT; controller reconciliation derives the
same bytewise-canonical three-Member set from active placement/allocation state.
The payload-bearing protobuf service is never registered on the management
listener. Consumers generate protobuf bindings with their own grpc/protobuf
toolchain.

`write_coordinator` adds a backend-neutral, node-local durable coordinator
journal. Before any caller-owned PREPARE side effect it persists the exact write,
payload, canonical three-Member set, and one fixed two-witness selection. It
records PREPARE and COMMIT acknowledgements only after mandatory injected
authenticated-evidence callbacks accept the pinned witness and exact metadata,
persists one canonical certificate before any COMMIT side effect, and retains partial COMMIT
progress for same-state-directory restart retry. It has no ABORT and never
switches to the third Member after an unknown result. Its checksummed,
fsync-backed atomic `FileStore` is another development full-snapshot baseline,
not a streaming coordinator log.

The coordinator is intentionally not wired into the data-node daemon or Replica
RPC client yet and does not establish cross-node quorum durability. The contracts
require injected PREPARE/COMMIT evidence checks but do not implement their
authentication; callbacks do not create independently signed third-party
attestations. There is still no outbound credential/topology route,
production primary coordinator, client-facing payload write RPC, replacement
coordinator recovery, confidentiality, or certified quorum repair.

```sh
zig build test
```
