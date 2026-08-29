# zettide-data-service-contracts

Shared data-service API contracts and authority safety model for Zettide.

The package contains no Raft, CLI, transport, or physical storage backend
dependencies. It owns the wire-neutral Replica/authority models plus the
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
network transport.
Consumers generate protobuf bindings with their own grpc/protobuf toolchain.

```sh
zig build test
```
