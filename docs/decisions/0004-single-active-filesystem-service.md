# 0004: Single-active filesystem service with multiple clients

- Status: Accepted (architecture choice; managed implementation is a target)
- Scope: First controller-managed POSIX/filesystem service
- Prerequisite: [0003: Storage product architecture](0003-storage-product-architecture.md)

## Decision

Each managed Filesystem has at most one active service owner. Multiple clients
submit operations to that owner, which serializes namespace mutations and the
metadata portions of data operations. This is not a single-client restriction.
Different filesystems can have different owners only when their underlying Pool
ownership and placement permit it.

The first implementation reuses BlobFilesystem and the existing filesystem
ports. It does not introduce a shared-writer TxFS dependency, per-directory
metadata sharding, or independent writers on different nodes. Read-only clients
also access the active service; a second process opening live media read-only
is not automatically a coherent read replica.

Controller management/authority changes use Raft. Per-file namespace and data
transactions remain owned by the filesystem engine, not the global controller
state machine. Controller Raft replication does not replicate inode trees or
file payloads. This decision does not select or claim a new distributed
namespace replication protocol: cross-node takeover remains blocked until the
backend has demonstrated recoverable durable state and storage-side fencing.

## Ownership and process boundary

The single-active invariant covers the actual BlobFilesystem engine owner, not
just a controller record, listener, frontend name, or data-node identity.
Authority identifies both the target node and the actual holder process boot
identity. Two processes on the same node cannot independently open it writable.

Existing process boundaries remain unchanged:

- NFS-Ganesha remains a separate process with its FSAL/C ABI adapter.
- Foreground FUSE remains an explicitly owned mount process.
- Managed lifecycle belongs to data-node composition/reconciliation.
- Until forwarding through one shared engine owner exists and is verified,
  NFS and FUSE must not independently open the same filesystem concurrently.

Multiple protocol frontends must eventually forward to the same authority and
serialization point, rather than each linking an independently writable engine.
This decision does not implicitly create that forwarding transport.

## Metadata responsibility

### Controller: authoritative management state

Introduce a distinct `Filesystem` resource rather than treating a filesystem
as an exported Catalog Volume. The candidate logical model is:

| Resource | Required information |
| --- | --- |
| Filesystem | Stable ID, logical Pool ID, name, description, backend kind, format/name profile, lifecycle, created/resource/deleted revisions |
| FilesystemPlacement | Filesystem ID, backend identity and local Pool binding, placement generation, eligible owner node |
| FilesystemAuthority | Filesystem ID, placement generation, holder node/process boot identity, authority epoch, lease identity/revision, activation/revocation phase |
| FilesystemExport | Filesystem ID, selected protocol, access policy, read/write mode, export generation, lifecycle |

These are logical requirements, not released protobuf messages or disk fields.
Exact wire fields and state enums require compatibility review when implemented.
Public clients cannot mark a resource ready, assign its epoch, or complete a
storage fence by editing resource fields.

Filesystem management must follow existing controller conventions:

- Mutations use the global durable request-ID/fingerprint domain and Raft apply.
- Updates/deletes use expected resource versions; authority actions additionally
  bind the exact placement generation and holder identity.
- Queries use ReadIndex. Heartbeats and listener reachability are observations,
  not evidence granting authority.
- Names are unique among live filesystems within a logical Pool. Deleted names
  can be reused; IDs and authority fencing history cannot be reused.
- Initial updates replace description only; identity, backend kind, Pool binding,
  and name profile are immutable until an explicit migration contract exists.
- A live Filesystem blocks logical Pool deletion. An unknown backend/data mode
  is not sufficient evidence to provision or activate a filesystem.
- Control-plane Pool identity and local on-media Pool identity remain distinct;
  they require explicit binding, not equality of names or paths.

Logical creation can return a provisioning resource without formatting media.
It must not imply a root inode exists or advertise a usable export. Backend
format and physical reclamation are separate, idempotent reconciler actions,
with durable intent recorded before their external side effects.

### Filesystem engine: persistent namespace and data state

Reuse the inode/dentry/orphan/reservation model in
[`blob_filesystem_format.zig`](../../libs/storage-engine/src/blob_filesystem_format.zig)
and transaction machinery in
[`blob_filesystem.zig`](../../libs/storage-engine/src/blob_filesystem.zig).
Do not create a second controller-owned inode table.

The engine owns file identity/generation, directory entries, link counts, modes,
UID/GID, timestamps, logical size, extents, sparse reservations, and orphan
lifetime. It atomically updates the affected objects for create, link, unlink,
rename, append, and truncate. An existing implementation is a reuse candidate,
not proof that all managed/multi-client crash semantics have passed.

A stable external file handle binds filesystem identity, inode identity, and
inode generation. Paths, export locators, and service epochs are not file
identity. Failover must not silently resolve an old handle to a newly allocated
inode. Changing service epoch fences access, but does not itself require
changing every surviving file's identity.

There is no public generic inode/dentry patch API with which callers assemble
namespace transactions. Clients invoke semantic filesystem operations.

### Protocol adapter: sessions, opens, locks, and caches

Protocol state is not one universal durable controller session table:

- POSIX open descriptions, offsets, and local VFS locks retain their existing
  frontend semantics. Their hot-path changes do not enter controller Raft.
- NFSv3 has no native OPEN/CLOSE session. Do not invent a per-open NFSv3 controller
  record or use an imaginary close event to reclaim an orphan.
- Future NFSv4 open/lock recovery, grace periods, and delegation recall require
  a separately specified durable protocol-state contract.
- A local VFS lock manager does not implement distributed multi-client locks.
  The current NFSv3 `nolock` profile must not be advertised as full multi-host
  POSIX locking.
- Serializing the server does not invalidate client page/dentry/attribute caches.
  Each frontend must satisfy its declared consistency, writeback, and sync rules.

Do not reclaim an unlinked object solely because its link count reached zero
or a gateway heartbeat expired. Open references, protocol handles, dirty data,
and recovery state must be resolved according to that frontend's contract.

## Activation, revocation, and takeover

The required ordering is:

1. Commit placement and candidate authority intent through Raft. Do not admit
   client I/O merely because a candidate record or local process exists.
2. Fence the old owner at every reachable storage/replay path, or establish a
   verified external hard fence. Persist the barrier; a timeout is not proof.
3. Recover the backend and pending transactions under the new epoch; validate
   stable filesystem identity, format, and placement binding.
4. Commit readiness against the same candidate, epoch, boot ID, and placement.
5. Activate only that ready authority locally, then publish its export. Lost
   replies, restarts, or reordered actions must not revive an older epoch.

Renewal preserves the ownership epoch while refreshing the live lease window.
A restarted holder has a new boot identity and must reacquire authority through
recovery; an old READY record alone is insufficient. Loss of control contact
stops new admission before the local lease deadline. An accepted revoke first
closes admission; completion requires safe drain/fencing, not elapsed time.

`FilesystemAuthority.epoch`, block `Volume.write_epoch`, range-lease tokens,
and export generation are distinct domains. The existing range-fence/reaper
mechanisms do not prove a whole filesystem owner or its replay paths fenced.

A local-only backend cannot fail over to a node lacking its durable state.
Missing storage, an unreachable unfenced writer, or incomplete recovery leaves
the service unavailable. Availability is not obtained by weakening these checks.

## Deletion

Filesystem deletion first commits deleting intent and rejects new exports,
authority grants, and opens through the managed service. Revoke access, resolve
protocol/open state, and fence/drain outstanding I/O before retiring the backend.
Physical reclamation follows durable deletion intent and keeps progress across
restart. Publish a terminal tombstone only at the defined completion point;
retain enough identity/history to reject delayed operations and stale handles.

Logical Pool deletion must not race filesystem provisioning or cleanup. A
filesystem tombstone is not proof that physical cleanup completed unless its
transition explicitly required that evidence.

## Delivery boundaries and verification

The initial controller slice is Filesystem CRUD with provisioning-only creation,
Pool dependency checks, durable dedup/CAS, ReadIndex queries, and atomic
WAL/snapshot recovery. It cannot report an active service or mountable export.
Authority, backend recovery, and managed export activation are separate slices.

Before managed service readiness is advertised, verify:

- concurrent metadata operations have a single serialization point;
- same-name create, cross-directory rename, replacement rename, hard links,
  unlink-open, append, and truncate preserve their transaction semantics;
- successful file/directory sync survives the failures claimed by the backend;
- old boot/epoch requests and delayed activation replies fail after takeover;
- controller restart/leader change cannot create a second active owner;
- backend/process restart resolves dirty/open/orphan state before admission;
- independent FUSE/NFS opens of the same live backend are rejected;
- unavailable storage/fencing blocks takeover and destructive cleanup.

The [POSIX profile](../posix-profile.md) remains the Linux FUSE conformance
profile. It is not an NFS conformance claim. The
[NFS FSAL status](../../services/nfs-fsal/README.md) and
[range lease integration limits](../range-leases.md) continue to apply.

## Non-goals of this decision

- Direct multi-writer namespace access from multiple data nodes.
- Per-file or per-directory controller Raft groups.
- Replacing the existing on-media filesystem format merely to add management.
- Claiming transparent open/lock failover or multi-host POSIX compliance without
  protocol-specific recovery and real mounted-client tests.

The controller also supports a non-executable single-owner candidate reservation:
registered node, actual service-process boot identity, and monotonic epoch.
Candidates block deletion and can only be cancelled with the exact binding.
They must not perform backend work and are not placement or access grants.
See [candidate semantics](../filesystem-metadata.md#candidate-reservation-not-an-io-grant).
The committed preparing/fencing/recovery/readiness phases remain future work.
