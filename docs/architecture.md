# Architecture

The engine writes immutable objects and publishes a new root through one
conditional anchor replacement. A successful transaction has four phases:

1. Stage immutable objects.
2. Prepare those objects durably.
3. Replace the anchor only if its version token is still current.
4. Stabilize the published anchor before acknowledging the transaction.

Backends expose version tokens and object references as opaque values. The
transaction layer never interprets physical LBAs, SCSI status, object-store
keys, ETags, or protocol-specific errors.

The logical anchor is a fixed 512-byte envelope. A SCSI backend may embed it in
a larger logical block and use that complete physical block as its opaque
version token. Every published envelope includes a monotonically increasing
generation and transaction identifier, so a physical anchor value is never
reused.

The contract distinguishes a definite conflict from an indeterminate outcome.
Indeterminate publication is resolved using the transaction identifier and the
parent chain stored in immutable commit records; it is never retried blindly.
Once a publication request may have reached storage, transport failure is
reported as indeterminate rather than as an ordinary error. Stabilization is
idempotent and may be retried.

Every immutable commit record stores its generation, globally unique
transaction identifier, optional parent commit reference, and filesystem root
reference. Resolution requires generations to decrease by one along the parent
chain and applies a caller-controlled traversal limit. A missing, malformed, or
inconsistent chain is an unresolved error rather than evidence of success or
failure.

An unchanged base anchor does not prove that an indeterminate request failed:
the request may still reach storage after the read. Resolution remains pending
until the transaction appears at its intended generation or another commit
advances the anchor. A future explicit fencing operation can force progress
when no other writer advances it.

## Transaction Coordination

The transaction coordinator snapshots one base anchor and owns one write batch.
It stages immutable objects, writes the commit record last, prepares the batch,
conditionally publishes the next anchor, and stabilizes a definite winner. The
published root must either belong to the transaction's batch or already be
loadable from the store.

A transaction is single-use. Conflicts and confirmed non-publications are
terminal. An indeterminate publication must be resolved before stabilization.
If publication succeeds but stabilization fails, only stabilization is retried;
the logical transaction is never republished. After backend recovery, terminal
resolution can detect that an unstable publication was rolled back.

## Planned Backends

The SCSI backend uses one logical-block COMPARE AND WRITE for anchor updates.
It owns append allocation and maps prepare/stabilize to cache synchronization.

An S3 backend can create immutable objects with `If-None-Match: *` and replace
a fixed anchor object with `If-Match`. ETags remain opaque version tokens.
Every backend runs the same contract scenarios in addition to its protocol
integration tests.

## Filesystem Semantics

Filesystem semantics live above this repository. Zettide will adapt its FUSE
layer to a backend-neutral filesystem interface. Existing littlefs volumes stay
single-writer; shared writable volumes use this engine.
