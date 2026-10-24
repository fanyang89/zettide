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
| Local protection | Existing local protection and conservative write/flush failure behavior retained; degraded writes and rebuild are not implied |
| SPDK exports | Existing Catalog NVMe-oF, iSCSI, and vhost adapters retained during protocol convergence; NVMe/TCP is the primary direction |
| Endpoint lifecycle | Registry, durable desired state, owner-only Unix control API, and endpoint daemon retained |
| Concurrent publication | Incomplete: registry currently allows one endpoint per Pool; shared Pool ownership and lease coordination must be addressed before lifting this restriction |
| VM lifecycle integration | Incomplete: exports are not a complete managed create/publish/attach/restart/detach lifecycle |

## Removed

- Raft-backed cluster controller, placement, heartbeats, and remote coordination.
- Distributed DataService/Replica RPC, signed two-witness write coordination,
  controller-managed leases, and the three-node Docker/file-member E2E profile.
- Shared data-service contracts, TxFS, CSI, and the cluster administration CLI.
- The `raftz` source dependency and controller/protobuf build targets.

These are retired capabilities, not deferred roadmap items.

## Remaining convergence work

Filesystem implementations and FUSE/NFS/dufs compatibility entry points remain
temporarily in the source tree, with their existing tests. They are scheduled
for removal, not further feature development. Their shared persistent-format
definitions must be audited before deleting dependencies.

Additional block protocol paths remain transitional. Removing them must not
silently reinterpret persisted endpoint frontend values.

Loop devices, regular files, unit tests, and focused export tests do not prove
real multi-disk durability or a complete virtualization integration. No current
path is advertised as production-ready.
