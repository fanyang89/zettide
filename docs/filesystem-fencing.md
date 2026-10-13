# Filesystem storage fence and recovery gate

## Implemented boundary

`libs/data-service-contracts/src/filesystem_fence.zig` provides a backend-neutral,
local storage gate with a checksummed, fsync-backed epoch journal. It is **not
wired into the controller, BlobFilesystem, NFS or FUSE**. The gate introduces no READY transition, export or on-media filesystem format.

The controller exposes non-executable candidates and a non-cancellable
`BeginFilesystemPreparation` intent that pins backend digest, placement generation
and owner. A trusted adapter may authorize storage preparation/recovery only
from the committed exact PREPARING binding after physical identity verification.
That adapter is not yet implemented. It must never convert CANDIDATE or a bare
epoch into permission to open or modify media.

## Identity and ownership

An immutable `Identity` binds controller cluster, logical Pool, Filesystem,
backend digest, root format and filename profile. The backend digest must cover
stable physical Pool/Member identities and the root Blob object's durable
identity/locator, **not** its changing tree checksum, a pathname or mountpoint.
The production derivation/catalog and verification adapter remain unimplemented.
`verify_identity` must check the actual opened backend, not echo caller input.

A `Binding` additionally binds placement generation, authority epoch, holder
Node and the actual engine process's boot identity. Boot IDs are nonzero opaque
16-byte values, regenerated on each process start. Pool/Filesystem/Node IDs use
canonical UUIDv7 octets. Cluster IDs are nonzero 16-byte controller identities.
Only root format 1 and the two existing filename profiles are supported.

The caller must hold exclusive ownership of the backend **and** its journal
before bootstrap/open and until all workers finish and the gate closes. The
module does not implement that process lock or distributed ownership protocol.
Two independent gate instances or two node-local copies of a ledger do not
fence one shared backend. Do not use this library as proof that concurrent
standalone FUSE/NFS opens are safe.

## Ordering

1. `prepare(binding)` validates trusted committed preparation, closes prior local
   readiness, waits for admitted guarded operations, and invokes `drain_flush`.
   The adapter must stop/drain **all** old routes, deferred work and replay, and
   sync physical storage. Only then is the new epoch durably journaled and a
   receipt returned. A local mutex is not proof of remote fencing.
2. `recover(binding)` requires the exact durable binding and trusted preparing
   authorization. Recovery runs under the same mutex, validates format/profile,
   resolves transactional/orphan state, and returns a nonzero recovery digest.
   The result is cached only in memory; it is not an access grant.
3. The future controller must validate matching fencing/recovery evidence and
   commit readiness. `activate(recovery)` checks the exact local recovery result
   and asks the trusted adapter to verify that committed readiness and a live
   lease window before enabling local admission.
4. `begin(binding)` checks exact durable binding, local readiness, current
   controller authorization and lease validity. The returned guard must be held
   until the **actual** I/O completes or cancellation has really drained it.
   All reads, namespace/data writes and sync paths must obey this boundary.
   Backend recovery is available only through the guarded recovery callback.

`authorize` must validate exact state/binding, not merely integer ordering.
For activation and payload it must also match the supplied recovery digest to
committed readiness, enforce conservative local lease deadlines and reject
stale renewal/activation replies. These authorization and lease adapters are
not implemented here. Callbacks must not reenter the gate.

Preparation can retry identically while still authorized, without discarding
local recovery. A prepared epoch alone never opens admission. Reopening always
starts unready, even if the controller still has a READY record. A new process
boot cannot reuse an old epoch: it needs a higher, freshly authorized epoch and
recovery. Placement generations cannot regress either.

## Durability and failure behavior

The module reuses `fence_service.FileStore` **in a dedicated filesystem ledger**,
not a block Volume or range-lease ledger. Domain-separated hashes cover the full
identity/binding. The high-water lookup key stays fixed across owner boots,
epochs and placement generations; an immutable identity key also rejects opening
existing history as another cluster, Pool, Filesystem, backend or profile.
Internal hash-derived UUID-shaped journal keys are not public time-based IDs.

Latest epoch is checked before historical operation lookup, so an old successful
prepare cannot return a stale success after a newer epoch has been installed.
A forged higher epoch still needs exact trusted authorization. A stale owner
cannot gain access by changing placement generation or boot identity.

`createLedger` is explicit exclusive bootstrap. Never recreate a missing journal
as a recovery fallback. Reopen rejects missing, corrupt and wrong-identity
history, and syncs the recovered file/directory before acknowledging an earlier
uncertain rename. Drain, persistence, recovery and zero recovery-digest failures
poison the gate: no further preparation or I/O succeeds until recovery/reopen.
No timeout alone constitutes a successful drain or a fence receipt.

The generic journal retains at most 16,384 records and rewrites an atomic full
snapshot on append. Capacity exhaustion fails closed; compaction, migration and
production scaling are not implemented. The underlying store's checksum and
validation are not cryptographic protection against malicious storage rollback.

## Verification and remaining integration

Tests cover candidate rejection, preparation/recovery/readiness ordering,
lease rejection, stale epoch/boot/generation and delayed activation, missing or
foreign journals, corruption, drain/rename/directory-sync/recovery failures,
restart repair, and an actual file write whose guard blocks a concurrent fence
until completion and sync.

Before enabling managed I/O, connect and test the committed PREPARING binding,
physical identity catalog/adapter, exclusive backend ownership, complete
all-target/old-route fencing, lease validation, real BlobFilesystem recovery and
mandatory gate usage by every payload/replay path. Missing storage or uncertain
fencing must leave the filesystem unavailable. No POSIX or NFS failover claim is
made by these library tests.
