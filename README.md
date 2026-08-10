# zettide-cawfs

`zettide-cawfs` is a transactional storage engine for filesystems that share a
single storage namespace across multiple writers. It publishes immutable state
through one conditionally replaced anchor.

The transaction layer targets a backend-neutral contract:

- immutable object creation;
- durable preparation before publication;
- atomic conditional anchor replacement;
- explicit conflict and indeterminate outcomes;
- durable completion before acknowledging a commit.

A first append-only backend slice maps that contract to immutable SCSI extents
and COMPARE AND WRITE publication.
A future object-store backend can map the same contract to conditional writes
such as Amazon S3 `If-Match` without exposing LBAs, CDBs, ETags, or HTTP status
codes to the transaction engine.

CAWFS owns the minimal persistent metadata model for shared writable volumes:
an immutable filesystem root references inode, directory-entry, and extent
B+trees. Zettide's backend-neutral FUSE and POSIX frontend uses BlobFilesystem
for local single-writer volumes and CAWFS for shared writable volumes.

Current file data support is deliberately narrow: one non-empty immutable
object and opaque extent reference may be written once to an existing empty
regular file. Payload and metadata preparation completes before conditional
anchor publication. Overwrite, multi-extent files, mutable `.data` allocations,
orphan reclaim and garbage collection, and general POSIX data semantics are not
implemented. Writable ownership and takeover still require external fencing.

Version 2 volumes use an anchor revision separate from filesystem generation
and persist an `active`, `quiescing`, `maintenance`, or `blocked` service mode.
Normal transactions are accepted only in `active` mode and cannot alter the
mode epoch. The maintenance coordinator durably publishes
`active -> quiescing -> maintenance -> active`, can block an in-progress
operation, and resolves ambiguous updates through immutable control ancestry.
External fence evidence and destructive garbage collection are not implemented
yet.

## Development

The project uses the Zig master nightly and Task 3.48.0 through mise.

```sh
task check
```

## Status

The repository is under active development and is not ready for production
data.

## License

MIT
