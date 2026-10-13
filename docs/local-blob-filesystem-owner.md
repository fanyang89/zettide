# Local BlobFilesystem owner prototype

`services/data-node/filesystem_blob_owner.zig` connects the
[Filesystem gate](filesystem-fencing.md) to an **existing regular-file
BlobFilesystem**. It is an in-process prototype, not a daemon or RPC service.
The controller authorizer, raw Pool/Member backend, remote fencing, full POSIX
handle/session layer and NFS/FUSE publication remain unimplemented. No current
controller RPC can commit READY, so the shipped controller cannot activate this
owner. Tests inject a trusted authorization model; they do not prove that
control-plane-to-data-plane integration is complete.

## Identity and ownership

- `probe` takes a shared file lock and validates the actual Blob store headers.
  Its domain-separated digest covers the store UUID and capacity, not pathname,
  mutable tree root, logical Pool/Filesystem IDs, owner or epoch. It does not
  prove a valid filesystem root or perform orphan recovery.
- This digest domain is **local-file-only**, not the production physical
  Pool/Member/root identity. Byte copies retaining UUID/capacity intentionally
  have the same digest. Do not treat a clone as independently initialized media,
  copy/reset fencing history, or give one backend multiple journal aliases.
- `createJournal` is explicit initial bootstrap. It exclusively creates a stable
  `.owner` sidecar and a durable gate journal; it is never a recovery fallback.
  Partial bootstrap failure is reported, not silently repaired or overwritten.
- `Owner.open` checks the binding against the separately supplied local
  node/process boot identity and requires trusted PREPARING authorization before
  opening files. That boot must come from process startup, not from a replayed
  controller response. It then holds exclusive nonblocking locks on both the
  sidecar and Blob file for ownership, validating the observed backend digest.
- The sidecar inode stays stable while the journal data file is atomically
  replaced. Never unlink/replace a live sidecar. Consistent, durable journal
  association and process startup identity are caller responsibilities.

These are kernel **advisory** locks for cooperating local processes. They do not
fence remote routes, protect against raw/unlocked file access or malicious disk
rollback, or turn read-only direct opens into coherent replicas. Normal
`storage.Storage.openFile` attempts, including shared readers, are excluded while
the owner holds the Blob lock. Paths can change without changing identity, but a
replacement Blob with another UUID is rejected.

## Preparation and recovery

1. Call `Owner.open` only for a committed PREPARING binding using a trusted
   `Authorization` adapter. It reads Blob headers but does not open a writable
   filesystem or recover orphans.
2. `prepare` uses the gate to drain guarded local work, sync the existing backend
   and persist the epoch barrier. Initial ownership excludes other cooperating
   local handles; this is not an all-target remote fence.
3. `recover` opens the actual BlobFilesystem only under that durable barrier.
   `Filesystem.openExpectedProfile` validates the selected root's filename
   profile **before writable orphan recovery**; root decoding validates format.
   Recovery and media sync produce a binding-associated recovery digest.
4. A future controller must commit matching readiness and supply valid lease
   authorization before `activate` admits file operations. A PREPARING reply or
   recovery result alone is insufficient.

The prototype never formats a missing/unformatted filesystem or manufactures
missing journal history. Wrong profile, failed recovery or uncertain persistence
leaves admission closed. A new process boot requires a newly authorized higher
epoch, not reuse of an old READY response.

## File operations and teardown

The deliberately small API exposes create-file, stat-path, read, write and sync.
Each retains the same gate mutex until the real engine operation completes.
Sync errors poison subsequent admission. Production code must not reach through
the owner's internal `native`, `blobs` or `gate` fields to bypass these methods.
The prototype has no open/close handles, distributed locks, namespace RPCs or
client authentication; it is not a complete POSIX service.

Callers must stop/join workers before teardown. `deinit` uses the new
`Filesystem.abort` path: it frees caches and closes handles **without committing
pending dirty state**, even after lease loss or a poisoned gate. Already committed
mutations are not rolled back. Graceful persistence requires an explicitly
successful authorized `sync` first. Existing ordinary `Filesystem.close` still
syncs; failed writable opens now abort instead of retrying dirty commits during
error cleanup.

## Verified

Tests use real formatted files to verify guarded write/sync/reopen, stable
identity across mutations, exclusion of competing owners/readers, stale boot and
epoch rejection, lost-lease admission closure, non-flushing teardown, profile
mismatch with byte-for-byte unchanged media, actual orphan recovery after fencing,
missing/replaced media, failed-sync poisoning and allocation-failure lock cleanup.
These tests do not validate mounted clients or remote failover.
