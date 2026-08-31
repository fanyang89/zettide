# Zettide Data Node

`services/data-node/` owns Zettide's data-node product composition and platform or
protocol adapters. It consumes the public `zettide_storage` module from
`libs/storage-engine/`; it must not use cross-directory relative imports into
the engine.

Current data-node/platform capabilities include the endpoint registry and daemon,
Catalog exports over NVMf TCP/RDMA, iSCSI, and vhost-user-blk, plus the Linux
FUSE/NFS/dufs adapters. These are component and compatibility lifecycles; they
do not yet form the final `zettide-data-node` managed Publication service.

Current compatibility surfaces remain unchanged:

- `zettide` CLI and its existing commands;
- `zettide endpoint serve` compatibility entry;
- `libzettide-nfs-backend.a`, `zettide/nfs_backend.h`, and `zettide_nfs_*` C ABI;
- endpoint control protocol and persisted desired-state format;
- SPDK export identities and lifecycle behavior.

`data_node_root.zig` is the named `zettide_data_node` module root. Tests, benchmarks,
SPDK consumers, and the NFS backend use explicit `zettide_data_node`/
`zettide_storage` imports. The legacy `zettide` facade is restricted to the
existing CLI sources.

The iSCSI path includes a shared SPDK service, per-Catalog target/LUN export,
endpoint locator wiring, and the remote `tests/automation/iscsi-catalog-fio.yml`
profile. It still lacks consumer-bound access generation and managed attachment
reconciliation.

Run `zig build test-data-node` for endpoint/SPDK adapter units,
`zig build test-compatibility` for CLI/frontend compatibility units, and
`zig build test-module-roots` for dependency-boundary checks.

`data_node_main.zig` and `data_node_service.zig` expose the DataService control
endpoint. The repository root build installs `zettide-data-node`; the daemon starts that
endpoint and registers its stable Node identity and advertised data endpoint
with the controller.

For development provisioning, configure all of `--state-dir`, `--member-file`,
`--member-id`, `--pool-id`, `--member-metadata-capacity`, `--member-capacity`, and
`--extent-size`. The daemon registers the file Member, advances a durable process
incarnation, and reports sequenced capacity heartbeats at the interval returned
by the controller. The target Pool must already exist.

Replica operations are persisted in `replicas.state`, fence evidence in
`fences.state`, accepted authority epochs/recovery evidence in `authority.state`,
the physical file-object generation in `member-generation.state`, and configured
participants in `write-catalog.state` plus per-generation `write-*.state`
snapshots. An exclusive `daemon.lock` prevents two processes from sharing
that state directory. The daemon binds the ledger to an opened backing-file
inode, validates allocations against its fixed geometry, rejects overlap,
retains deleted extents in quarantine, and reports
free/allocated/reserved/retired extent counts. Lease deadlines remain
process-local and fail closed after restart; the maximum accepted write epoch is
durable. An uncertain parent-directory sync poisons the affected ledger until
restart/reopen rather than allowing a later operation to overwrite it. Omitting
all seven options keeps Replica, fence, recovery, and Member
heartbeat operations disabled while holder/lease diagnostics remain available.

This file-member backend now includes a node-local, daemon-owned write
participant manager. Its lifetime-held exclusive catalog lock prevents duplicate
manager attachment. Catalog v3 and participant FileStore v2 persist an immutable
Replica/canonical-Member/controller-pinned witness binding plus the
full signed certificate. The manager retains retired generations for recovery
evidence, validates the complete active Replica and physical-object generation
before each 4 KiB-aligned positional write, synchronizes the member file, and
eagerly drains a durable signed COMMIT on startup. Normal admission checks the exact live ready
authority and durable fence; first-time certified decisions and replay bypass
lease expiry through the same drain guard but are
rejected after a different/higher fence. Replica mutation and fencing take the
same participant/control barrier through the durable fence append; undecided or
poisoned state blocks deletion/fencing, and deletion durably retires the catalog
entry before allowing generation rollover.

`ConfigureWriteParticipant` now carries both the legacy canonical Member list
and exactly three controller-derived Member/Node/key identities. The management
boundary strictly validates their ordering, equality, key IDs, Ed25519 points,
and distinct signer Nodes/keys before cataloging the immutable binding. Legacy keyless configuration remains fail closed. The production daemon loads
an owner-only signing seed, registers its public key through the controller's
fill-once identity path, and requires the provisioned local witness identity to
match before participant readiness. PREPARE/COMMIT remain unavailable on the management
listener and cannot lazily create an unconfigured participant.

The optional, separately bound `ReplicaTransport` is HMAC authenticated and
returns independently verifiable Ed25519 evidence. PREPARE signs the exact
durable write and attestation; COMMIT accepts only the original two signed
PREPARE records, persists/verifies that decision through the participant, and
signs the exact completed result. Legacy unsigned requests and responses fail
closed. Metadata listener separation and authentication remain.
Requests are HMAC-SHA-256
authenticated with receiver-scoped pairwise node keys and bind source node,
target node, a fresh per-call challenge, method, and exact protobuf bytes. Every
post-authentication response MAC binds that challenge plus status code, status
message, and payload, so stale or success-to-failure substitutions fail closed.
Captured mutation requests may still be replayed only with the same bytes and
rely on signed participant durable idempotency plus current
physical-backend validation. Tests verify that this service and `DataService` are not
registered on each other's listeners and that keyless, reordered, mismatched,
wrong-key-ID, and duplicate-Node configurations fail closed.

The daemon can enable this listener only when the file-member composition and
all six explicit development options are present:

```text
--replica-listen HOST:PORT
--replica-advertise HOST:PORT
--replica-key-file PATH
--replica-outbound-key-file PATH
--replica-signing-seed-file PATH
--replica-allow-plaintext true
```

The signing-seed file contains exactly one nonzero 32-byte Ed25519 seed as 64
lowercase hexadecimal characters with an optional final LF. It must be owned by
the daemon user and have no group/world permission bits; owner-only modes such
as 0400, 0600, and 0700 are accepted. It is non-symlink, bounded,
startup-loaded, retained only inside the scrubbed signer,
and enrolled as the Node's immutable generation-1 public key. A controller key
conflict, catalog/signer mismatch, or local Member/Node mismatch fails startup.
The bounded `tests/e2e/registration-migration.sh` gate exercises these fills
through the real controller RPC and daemon startup path. There is currently no
online rotation or revocation protocol.

The HMAC key file contains one `SOURCE_NODE_UUIDV7 64_HEX_KEY` pair per non-local
peer. It must be a regular file owned by the daemon user with no group/world
permission bits and is opened without following symlinks. It is bounded, parsed
strictly, copied into the authenticator, and scrubbed on release. Keys are
receiver-scoped: the same source uses a different key for each target. This
inbound file configures receiver verification only. The distinct outbound file
contains `TARGET_NODE_UUIDV7 TARGET_RECEIVER_KEY` entries; it is validated and
scrubbed under the same owner-only/non-symlink policy, copied into the coordinator
manager, and never aliased to inbound credentials. Keys are startup-loaded
configuration, not a versioned or rollback-protected durable key
ledger; replacement currently requires a daemon restart. The advertised endpoint
is persisted in controller Node metadata and survives snapshot/restart. Upgrade
from a legacy empty endpoint uses a Raft-applied, identity-matched fill-once
transition; a different existing endpoint fails closed. Missing, partial, zero,
duplicate, local-peer, malformed, or insecure-file configuration fails closed.

`--replica-allow-plaintext true` is intentionally conspicuous: application HMAC
provides request/response authenticity but not payload confidentiality. This
mode is for the Docker/file-backend development profile, not production.
PREPARE and COMMIT results are independently signed and the participant verifies
the controller-pinned two-witness decision. The internal coordinator loads the
separate outbound target-key registry, obtains authenticated durable arm acks
from all three routes before its first intent, and then performs local plus the
first canonical remote PREPARE/COMMIT. Success is returned only after both
participants and the coordinator completion are durable. Real-socket tests arm a
private one-shot receiver fault pinned to the SHA-256 of the exact protobuf
request bytes after durable PREPARE or COMMIT processing but before response authentication;
grpc-lite then emits only an unsigned failure,
the client rejects the absent authenticated response, and exact retry/restart
retrieves the durable evidence. Remote witness admission
uses the unchanged canonical primary authority transcript with a process-local,
ephemeral lease window. Runtime tracks the exact current READY binding separately
from a staged renewal candidate, so witness-first renewal does not replace a still-live
current authority; READY atomically promotes the candidate. Restart drops both windows
and requires controller restage.
The API rejects requests larger than 1 MiB, unaligned ranges, overflow, and ranges not fitting every
route's common logical length before creating an intent. It is process-local and is not registered on
`DataService` or `ReplicaTransport`; there is no client-facing write API or host publication. The excluded third Replica remains
behind, a fixed witness can leave an operation UNKNOWN, and only same-directory
coordinator recovery is supported. An armed node without matching signed local
completion cannot certify an empty recovery frontier. Confidential transport,
key rotation/revocation, replacement recovery, read/repair, NVMf user-data
replication, and authority-gated Publication remain subsequent steps. See `tests/e2e/README.md` for the Docker Compose profile.
