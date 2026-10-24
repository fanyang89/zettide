# 0005: Single-node VM block storage

- Status: Accepted
- Supersedes: ADR 0003 and ADR 0004; the filesystem, controller, DataService,
  and distributed-daemon requirements of ADR 0001; filesystem-specific clauses
  of ADR 0002 (the one-package rule remains accepted)

## Decision

Zettide is a single-node block storage system for virtual-machine disks. It
retains its own Catalog/Volume engine, local Pool/Member formats, extent maps,
and local multi-disk protection. It is not a general-purpose filesystem or a
distributed storage platform.

The same storage node may serve consumers on the local host or on other hosts.
Each writable Volume has one authorized consumer. Network access does not imply
storage-node high availability or permission for concurrent writers.

### Ownership

- `libs/storage-engine/` owns the backend-neutral block engine, persistent
  formats, local protection, validation, journal, and recovery.
- `services/data-node/` owns Linux storage adapters, SPDK composition, endpoint
  lifecycle, and the local operator CLI.
- A single process owns each writable Pool. Reuse the existing endpoint daemon
  rather than introducing a replacement cluster controller or RPC framework.
- qtr and PVE remain external consumers; their implementations are not built or
  tested by this repository.

### Non-goals

Remove the cluster controller and Raft integration, remote Replica protocol,
cross-node authority and lease coordination, TxFS, and CSI. Retire the
BlobFilesystem/FUSE/NFS/dufs product line and its conformance matrix.

NVMe/TCP is the intended primary block frontend. Existing iSCSI, RDMA, and vhost
paths are transitional, not mandatory parallel delivery gates; their removal
must account for persisted endpoint state. Snapshot, clone, online expansion,
protection migration, and erasure coding are not baseline delivery requirements.

### Safety and compatibility

Scope reduction must not remove local protection merely because it uses terms
such as replica, quorum, authority, or journal. Local Pool agreement and data
recovery are distinct from the retired cross-node protocol.

Preserve the current conservative write/flush failure behavior. Do not advertise
degraded writes, online rebuild, or automatic replacement without an implemented
and validated recovery path. Never weaken durability acknowledgement to reduce
code size.

Do not renumber persistent enum values or reuse retired feature bits. Existing
formats must either remain correctly decoded or be explicitly rejected; never
reinterpret a Blob filesystem as a Catalog. Preserve destructive-operation
planning, confirmation, identity verification, and exclusive ownership checks.

### Delivery

Remove independent branches first, then retire filesystem entry points and
their dependencies, then narrow block protocol composition. Each slice must
retain the regular non-incremental test and check gates. Transitional source is
not a promise to continue the retired product line.

Multi-Volume publication needs explicit Pool ownership and lease coordination.
The current one-endpoint-per-Pool restriction is not removed by this decision;
simply deleting its guard would be unsafe.
