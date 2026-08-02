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
