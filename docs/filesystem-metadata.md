# Controller-managed Filesystem metadata

## Implemented boundary

`zettide.controller.v1.FilesystemService` implements logical Filesystem CRUD
under the [single-active architecture](decisions/0004-single-active-filesystem-service.md).
Mutations are committed through Raft; queries use ReadIndex. Creation records a
`PROVISIONING` intent only. It does not format media, attach an existing Blob,
create a root inode, assign a service owner, grant access, or publish an export.

Filesystem placement, authority, recovery, and managed NFS/FUSE activation are
not implemented. No API in this slice can mark a filesystem ACTIVE or READY.
Existing standalone FUSE/NFS paths do not automatically consume these records.

## Resource and lifecycle

A Filesystem contains:

- `id`, `pool_id`, `name`, and `description`;
- `backend_kind = FILESYSTEM_BACKEND_KIND_BLOB`;
- immutable `name_profile` and desired filesystem root `format_version = 1`;
- `lifecycle_state`, `created_revision`, `resource_version`, `deleted_revision`.

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

All live records in this slice are unmaterialized provisioning intents. Delete
cancels that intent and retains a `DELETED` tombstone. It does not erase physical
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

Create/Update/Delete use `FilesystemMutationRequest`; their names determine the
operation, not a caller-supplied operation enum.

| RPC | Required fields | Other fields |
| --- | --- | --- |
| CreateFilesystem | request_id, filesystem_id, pool_id, name, backend_kind, name_profile | description optional; expected_resource_version must be zero |
| UpdateFilesystem | request_id, filesystem_id, expected_resource_version | description replaces the old description, including empty; omit all create-only fields |
| DeleteFilesystem | request_id, filesystem_id, expected_resource_version | omit description and all create-only fields |

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
- `NOT_FOUND`: missing/deleted resource or create against a missing/deleted Pool;
- `ALREADY_EXISTS`: used Filesystem ID or conflicting live Pool-scoped name;
- `FAILED_PRECONDITION`: stale resource version or request-ID semantic conflict;
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

Current commands use **v11** and snapshots **v14**, accepting legacy commands
v1-v10 and snapshots v2-v13. Filesystem commands require v11 and retained
Filesystem history requires snapshot v14. Upgrade controller voters together;
older binaries cannot restore v14 snapshots, even if the public API was unused.

Snapshots retain the global request history and a canonical Filesystem-view
digest. Restore replays Filesystem mutations in revision order, using historical
Pool availability, verifies retained outcomes and the resulting view, and
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
legacy format gates, corrupt snapshot rejection, and allocation-failure atomicity.

Real RPC tests cover pagination, two WAL/snapshot restarts, tombstones, and
historical retries. The three-voter runtime test covers creation/retry across
leader failover and deletion followed by former-leader catch-up. These tests do
not validate managed filesystem activation or POSIX payload behavior.
