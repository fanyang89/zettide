# Scope and implementation status

The authoritative product boundary is [ADR 0005](../../decisions/0005-single-node-vm-block-storage.md).
The former cumulative Tier 1/2/3 roadmap no longer applies.

## Retained product

Single-node VM block storage, using the in-house Catalog/Volume engine and local
multi-disk protection. Local and remote virtualization hosts may consume distinct
Volumes; each writable Volume has one authorized consumer. A storage-node outage
does not trigger automatic storage failover.

| Area | Implementation status |
| --- | --- |
| Pool/Member formats and recovery | Local format, authority scan, control journal, validation, and recovery primitives retained |
| Catalog block engine | Multi-Volume metadata, extent mapping, writable backend, and data lease retained |
| Local Pool CLI | Plans and provisions Catalog-mode Pool metadata with confirmation; initializes no Catalog root or Volume |
| Local protection | Existing local protection and conservative write/flush failure behavior retained; degraded writes and rebuild are not implied |
| SPDK exports | Catalog NVMe/TCP only; retired protocol state and options are rejected without automatic conversion |
| Endpoint lifecycle | Registry, durable desired state, owner-only Unix control API, and endpoint daemon retained |
| Concurrent publication | Incomplete: registry currently allows one endpoint per Pool; shared Pool ownership and lease coordination must be addressed before lifting this restriction |
| VM lifecycle integration | Incomplete: exports are not a complete managed create/publish/attach/restart/detach lifecycle |

## Removed

- Raft-backed cluster controller, placement, heartbeats, and remote coordination.
- Distributed DataService/Replica RPC, signed two-witness write coordination,
  controller-managed leases, and the three-node Docker/file-member E2E profile.
- Shared data-service contracts, TxFS, CSI, and the cluster administration CLI.
- The `raftz` source dependency and controller/protobuf build targets.
- Blob/BlobFilesystem, filesystem ports, FUSE, NFS/FSAL, dufs, and their CLI,
  conformance, remote automation, and benchmark profiles.
- Unicode normalization, filesystem test-suite dependencies, scheduled raw Blob
  performance harnesses, and the now-unused grpc-lite/profiling build dependency.
- iSCSI, RDMA/RXE, and vhost block adapters and protocol automation profiles.
- Fixed and scheduled raw Blob data-plane adapters; SPDK storage integration now
  uses an authenticated Catalog Volume rather than a raw Blob Pool.
- Library Blob/scheduled Blob provisioning. Catalog is the creation default;
  retired option values are rejected before storage I/O, not silently converted.
- The legacy fixed-three MemberSet and generation coordinator, plus the unused
  ReplicaEndpoint adapter. Current Catalog Pool coordination is retained.

These are retired capabilities, not deferred roadmap items.

## Remaining convergence work

Filesystem and raw Blob I/O entry points are gone. Retired format bits, Blob
geometry checks, and low-level local format/layout primitives remain for safe format
recognition and existing engine validation. They do not implement file semantics
or a supported Blob export. No on-media enum values or feature bits were reused.
Fixed-v1 Member and journal codecs also remain for safe identification. Pool
opens release old Member locks and exclude them from authority; legacy-only
input returns `LegacyMemberUnsupported`. Mixed input never promotes legacy
Members into dynamic Pool voters or data placements.

`test-catalog-io` covers one- and three-Member Catalog reopen, matching-copy
reads, write/flush failures on every replica, whole-lease freeze, and Linux
worker ordering/drain. The fixture initializes a test Volume through the real
journal; it is not a new operator Volume-management command.
Retired Blob media rejection is covered by the storage-engine suite using
low-level format fixtures, without a product Blob creation path.

The raw-disk creation planner now accepts only Catalog mode and fixed one- or
three-device profiles. Its versioned confirmation-token domain has changed;
obtain a fresh plan rather than reusing a token from a filesystem command.

Protocol composition is now TCP-only. Persisted TCP frontend value `3` is
unchanged; v1 state and retired v2 values are rejected without rewriting state.
Full local Volume management and coordinated multi-Volume publication remain
incomplete; shrinking the protocol surface does not complete those workflows.

Loop devices, regular files, unit tests, and focused export tests do not prove
real multi-disk durability or a complete virtualization integration. No current
path is advertised as production-ready.
