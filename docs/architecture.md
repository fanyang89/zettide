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

The contract distinguishes a definite conflict from an indeterminate outcome.
Indeterminate publication is resolved using the transaction identifier and the
parent chain stored in immutable commit records; it is never retried blindly.

## Planned Backends

The SCSI backend uses one logical-block COMPARE AND WRITE for anchor updates.
It owns append allocation and maps prepare/stabilize to cache synchronization.

An S3 backend can create immutable objects with `If-None-Match: *` and replace
a fixed anchor object with `If-Match`. ETags remain opaque version tokens.

## Filesystem Semantics

Filesystem semantics live above this repository. Zettide will adapt its FUSE
layer to a backend-neutral filesystem interface. Existing littlefs volumes stay
single-writer; shared writable volumes use this engine.
