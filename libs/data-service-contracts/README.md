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

`write_evidence` defines fixed-size Ed25519 witness identities plus independently
verifiable PREPARE and COMMIT evidence. Domain-separated transcripts bind the
protocol version, signer Node, witness Member, key ID/public key, exact write
transaction digest, full PREPARE attestation, and exact certificate/result.
Signing keys are constructed from an owned seed that is scrubbed on release;
private bytes are never exposed.

`write_coordinator` adds a backend-neutral, node-local durable coordinator
journal. Before any caller-owned PREPARE side effect it persists the exact write,
payload, immutable canonical three-witness identity set, and one fixed
two-witness selection. It strictly verifies and persists signed PREPARE/COMMIT
evidence, persists one canonical certificate before any COMMIT side effect, and
retains both signed PREPARE records and both signed COMMIT records for the latest
completed transaction. A later completion replaces `last_completed`; this is not
an append-only transaction history. Partial COMMIT progress supports
same-state-directory restart retry.
It has no ABORT and never switches to the third Member after an unknown result.
Its checksummed, fsync-backed atomic `FileStore` is another development
full-snapshot baseline, not a streaming coordinator log. FileStore v2 migrates
only pristine unsigned v1 genesis; any unsigned pending/decided/history state is
quarantined as `UnsignedCoordinatorState` rather than fabricating signatures.

The coordinator is intentionally not wired into the data-node daemon or Replica
RPC client and does not establish cross-node quorum durability. The current
participant `CommitCertificate` and Replica RPC protobuf still carry unsigned
attestations, so participants cannot independently validate the coordinator's
signed evidence. Controller-proven key provenance, durable distribution,
rotation/revocation, outbound topology/credentials, production fanout,
client-facing payload write RPC, replacement-coordinator recovery,
confidentiality, and certified quorum repair remain future work.

```sh
zig build test
```
