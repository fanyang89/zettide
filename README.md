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

The project does not embed filesystem semantics. Zettide supplies the FUSE and
POSIX-facing layer, with littlefs retained as its local single-writer backend
and this engine used for shared writable mounts.

## Development

The project requires Zig 0.16.0 and Task 3.48.0.

```sh
task check
```

## Status

The repository is under active development and is not ready for production
data.

## License

MIT
