# Controller-managed Filesystem metadata

## Implemented boundary

`zettide.controller.v1.FilesystemService` implements logical Filesystem CRUD
and single-owner candidate/preparation intents
under the [single-active architecture](decisions/0004-single-active-filesystem-service.md).
Mutations are committed through Raft; queries use ReadIndex. Creation records a
`PROVISIONING` intent only. It does not format media, attach an existing Blob,
create a root inode, assign a service owner, grant access, or publish an export.

Executable Filesystem authority, placement, fencing, recovery, and managed
NFS/FUSE activation are not implemented. Candidate reservation and preparation intent are metadata only. No API in this slice can mark a filesystem ACTIVE or READY.
Existing standalone FUSE/NFS paths do not automatically consume these records.

## Resource and lifecycle

A Filesystem contains:

- `id`, `pool_id`, `name`, and `description`;
- `backend_kind = FILESYSTEM_BACKEND_KIND_BLOB`;
- immutable `name_profile` and desired filesystem root `format_version = 1`;
- `lifecycle_state`, `created_revision`, `resource_version`, `deleted_revision`;
- `authority_state`, `authority_epoch`, `candidate_node_id`, `candidate_boot_id`;
- `backend_digest` and `placement_generation` (empty/zero until PREPARING).

The root format version is not the Member format version or controller command
version. It is desired metadata, not evidence of an initialized backend.

Names are bytewise case-sensitive, unique among live Filesystems within one
logical Pool, and limited to 127 UTF-8 bytes. Description is at most 1024 UTF-8
bytes. The filename profile does not change management resource-name comparison.
Supported filename profiles are explicit:

- `FILESYSTEM_NAME_PROFILE_LEGACY_RAW`: the case-sensitive profile appropriate
  to the existing POSIX/FUSE path;
- `FILESYSTEM_NAME_PROFILE_PORTABLE_V1`: the separately defined
  [portable name profile](portable-name-profile.md), including case folding.

Neither profile selection nor a metadata response is a POSIX conformance claim.
Unspecified or unknown backend/profile values are rejected.

Creation produces an unmaterialized provisioning intent. Delete requires no
candidate or preparation, cancels that intent, and retains a `DELETED` tombstone. It does not erase physical
data. Get/List hide deleted records; the successful delete response contains the
tombstone and deletion revision. Names may be reused after deletion; IDs cannot.

**Future placement integration must gate this deletion path before any media
side effects are introduced.** Once placement or initialization can start,
delete must coordinate revoke/drain/cleanup rather than immediately tombstoning.

A live Filesystem blocks logical Pool deletion. Deleted provisioning records do
not. Creation requires a live Pool; updating/deleting a Filesystem does not
change the Pool's resource version. Logical Pool membership does not prove that
a particular on-media Pool has Blob data mode or eligible capacity. Those checks
belong to provisioning, which is not implemented here.

## Mutation RPCs

All mutation RPCs use `FilesystemMutationRequest`; their names determine the
operation, not a caller-supplied operation enum.

| RPC | Required fields | Other fields |
| --- | --- | --- |
| CreateFilesystem | request_id, filesystem_id, pool_id, name, backend_kind, name_profile | description optional; expected_resource_version must be zero |
| UpdateFilesystem | request_id, filesystem_id, expected_resource_version | description replaces the old description, including empty; omit all create-only fields |
| DeleteFilesystem | request_id, filesystem_id, expected_resource_version | omit description and all create-only fields; no candidate may exist |
| ProposeFilesystemAuthority | request_id, filesystem_id, expected_resource_version, holder_node_id, holder_boot_id, expected_authority_epoch | omit all creation/description fields; observed epoch is zero before the first proposal |
| CancelFilesystemAuthority | request_id, filesystem_id, expected_resource_version, holder_node_id, holder_boot_id, expected_authority_epoch | omit all creation/description fields; epoch must be nonzero and binding must match; CANDIDATE only |
| BeginFilesystemPreparation | request_id, filesystem_id, expected_resource_version, holder_node_id, holder_boot_id, expected_authority_epoch, backend_digest | exact candidate binding; nonzero 32-byte backend digest; omit all creation/description fields |

CRUD requests must omit the authority-only fields. Only Begin accepts
`backend_digest`; other operations must omit it.

`filesystem_id` is a **caller-selected canonical UUIDv7**, unlike server-generated
IDs in CreatePool/CreateVolume. Select one fresh ID per new resource and preserve
it across retries. Pool ID is also canonical UUIDv7. Request IDs are nonempty
UTF-8 strings up to 127 bytes in the controller's global request-ID domain.

A timeout is an unknown outcome. Retry the exact request with its original
request ID and fields. Success and committed business rejections are retained,
including stale versions, missing Pools, name conflicts, and resource limits
that can be recorded within the request-history bound. Corrected fields or a
new attempt after a dependency changes require a new request ID. Malformed
requests rejected before proposal do not reserve a request ID.

Exact replay returns the **historical response**, not current resource state.
For example, retrying an old successful Create after deletion returns its
original PROVISIONING response but does not recreate the object; Get returns
NOT_FOUND. Reusing an ID with different semantics, including across resource
types, fails.

Status mapping:

- `INVALID_ARGUMENT`: malformed IDs, invalid fields/profile, oversized input;
- `NOT_FOUND`: missing/deleted resource, create against a missing/deleted Pool, or a
  proposal targeting an unregistered Node;
- `ALREADY_EXISTS`: used Filesystem ID, conflicting live Pool-scoped name or reserved backend digest;
- `FAILED_PRECONDITION`: stale resource version/authority epoch, candidate state or
  binding conflict, or request-ID semantic conflict;
- `RESOURCE_EXHAUSTED`: Filesystem/history limits;
- leadership/quorum failures follow existing controller RPC behavior.

The CLI exposes `zettidectl controller filesystem create|get|list|update|delete`;
see the [CLI examples](../services/cli/README.md#filesystem-metadata). Create
requires `--filesystem-id` and defaults `--name-profile` to `legacy-raw`. Lists
use `--after-filesystem-id`, not a base64 page token. Mutation RPC/output errors
preserve the request ID needed for an exact retry, including generated IDs.
Generated Go bindings also expose `FilesystemServiceClient`.
A protobuf JSON Create request is:

```json
{
  "request_id": "create-files-1",
  "filesystem_id": "0198f54d-5c2a-7000-8000-000000000301",
  "pool_id": "0198f54d-5c2a-7000-8000-000000000001",
  "name": "files",
  "description": "Shared file service",
  "backend_kind": "FILESYSTEM_BACKEND_KIND_BLOB",
  "name_profile": "FILESYSTEM_NAME_PROFILE_LEGACY_RAW"
}
```

Use an existing Pool ID and a fresh Filesystem ID, not these illustrative IDs.

## Candidate reservation (not an I/O grant)

The trusted control plane can reserve exactly one prospective service process:

```text
NONE -- ProposeFilesystemAuthority --> CANDIDATE
CANDIDATE -- CancelFilesystemAuthority --> NONE
CANDIDATE -- BeginFilesystemPreparation --> PREPARING
```

Proposal requires a live Filesystem, an existing registered Node, the current
resource version and last observed authority epoch. `holder_boot_id` is an
opaque nonzero 16-byte identity for the actual prospective engine-owning
**process**, freshly generated on every process start, not a client session or
host boot identity. Registration alone does not prove backend eligibility,
process liveness, or ownership; no such attestation is implemented yet.

A successful proposal sets `authority_epoch` to its Raft commit index, advancing
it monotonically. Existing candidates cannot be overwritten, even for the same
node/boot. Description updates leave the binding/epoch intact but advance the
resource version. Delete is blocked while a candidate exists. Cancellation
requires the current resource version and the exact node/boot/epoch binding;
it clears the candidate but **retains the epoch**. A new proposal must observe
that retained epoch, and commits a larger one. There is no candidate TTL or
automatic replacement on node failure, timeout, or controller leader change.

All outcomes use the shared durable request-ID domain. Replaying an old
successful proposal returns its historical candidate, even after cancellation
or replacement; this must never be treated as current authority. Get/List use
ReadIndex to expose the current binding. No candidate response, epoch, or
ReadIndex observation is a storage access capability.

`CANDIDATE` **must not trigger any external side effect**: no media formatting,
backend open/recovery, writes, export publication, or client admission. This is
why cancellation needs no holder acknowledgement or storage fence in this
slice. Do not reuse this cancel operation to revoke an engine that may have
touched storage. The current reconciler and standalone FUSE/NFS processes do
not act on candidate or preparation records. The CLI remains CRUD-only;
generated clients expose the three authority-intent RPCs.

## Non-cancellable preparation

`BeginFilesystemPreparation` commits PREPARING only from the exact CANDIDATE,
checking the current resource version, node, process boot and authority epoch.
It pins the nonzero 32-byte `backend_digest` and assigns `placement_generation`
from the Begin commit index. The authority epoch stays unchanged. Description
updates can still advance resource_version, but cannot change any pinned field.
The generation, epoch and resource version are distinct, not interchangeable.

A digest already reserved by any Filesystem is rejected, even across logical
Pools. The trusted resolver must supply a canonical digest covering stable
physical Pool/Member and root-object identity, independent of the claimant
Filesystem, logical Pool, owner, epoch or pathname. This duplicate check is not
physical attestation: arbitrary different hashes can alias one actual backend.
The real catalog, physical verification and all-path ownership adapter remain
unimplemented; see [storage gate requirements](filesystem-fencing.md).

Once PREPARING, direct cancellation, deletion, re-proposal and backend rebinding
are rejected. A retry with the original Begin request ID/fields returns its
historical result without changing state; changing fields under that ID fails.
A different request ID cannot repeat the transition or change the reservation.
The live Filesystem continues to block Pool deletion.

**There is currently no transition out of PREPARING**, even after owner failure.
This is an intentional safety barrier, not a completed provisioning workflow.
Do not interpret it as fenced storage, successful recovery, READY or permission
for payload I/O. No backend operation is launched by the RPC. Future adapters
must first validate the committed exact binding, then fence/drain old routes,
recover the backend and commit matching readiness. Failed or uncertain work
must retain the pin; unpinning, takeover and deletion require a separate durable
fencing/cleanup protocol, not this candidate cancellation RPC.

## Query RPCs

- `GetFilesystem(GetFilesystemRequest{filesystem_id})` returns one live record.
- `ListFilesystems(ListFilesystemsRequest{pool_id, after_filesystem_id, page_size})`
  returns live records sorted by Filesystem ID.

Page size defaults to 32 and is capped at 32 to keep worst-case descriptions
within the management stream's response budget. Continue with
`after_filesystem_id = next_after_filesystem_id`. An empty continuation means
exhaustion. The cursor is a lexical boundary and remains usable after its record
is deleted. Pagination is not a frozen multi-page snapshot. An unknown/deleted
Pool with no live Filesystems yields an empty list.

## Persistence, compatibility, and security

Current commands use **v13** and snapshots **v16**, accepting legacy commands
v1-v12 and snapshots v2-v15. Filesystem CRUD requires command v11/snapshot v14;
candidate operations require v12/v15; Begin requires v13/v16. Legacy v14/v15
snapshots retain their original digest and retry fingerprints during validation,
then upgrade to the preparation-aware digest. Upgrade controller voters together;
older binaries cannot restore v16 snapshots, even if the new API was unused.

Snapshots retain the global request history and a canonical Filesystem-view
digest. Restore replays Filesystem mutations in revision order, using historical
Pool/Node availability, verifies retained outcomes and the resulting view, and
validates Pool deletion against historical Filesystem lifetimes. Installation
is atomic, including allocation failures. Terminal IDs remain in the digest and
history. No filesystem data or inode tree is included in controller snapshots.

Limits are 10,000 Filesystem IDs including tombstones and the existing 50,000
global request records. There is no history compaction/Filesystem GC yet.

These management RPCs inherit the controller's trusted-network restriction;
resource IDs are not credentials. CRUD availability does not imply filesystem
client authentication, UID/GID mapping, export authorization, or usable I/O.

## Verified behavior

State-machine tests cover create/update/delete, immutable-field validation,
Pool-scoped names, name reuse without ID reuse, durable CAS rejections,
cross-resource request-ID conflicts, Pool deletion guards, historical replay,
legacy format gates, v14/v15 upgrades, candidate/backend exclusivity, stale boot/epoch
rejection, retained epochs, preparation pins, corrupt binding rejection, and
allocation-failure atomicity.

Real RPC tests cover pagination, two WAL/snapshot restarts, tombstones, and
historical retries, candidate bindings, epoch advancement and PREPARING pins. The three-voter
runtime test covers candidate preservation and deletion protection across leader
failover, cancellation/deletion for unprepared candidates, and persistent
PREPARING reservations after former-leader catch-up. These tests do
not validate managed filesystem activation or POSIX payload behavior.

A separate [storage fence/recovery gate](filesystem-fencing.md) now provides the
backend-neutral durable barrier foundation. It is not connected to these RPCs;
CANDIDATE still cannot authorize any backend work or client admission.
