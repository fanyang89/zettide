# Filesystem Semantics

This document defines the behavior covered by the Zettide test suites. Linux
FUSE is the only mount adapter currently implemented. Windows builds verify the
portable container core, but do not yet provide a WinFsp filesystem.

On Linux, `serve dufs` supervises an external dufs process over a private FUSE
mount. It does not add filesystem semantics beyond those exposed by FUSE; HTTP,
WebDAV, authentication, and TLS behavior belong to dufs.

## Supported Operations

- Regular files: create, open, read, write, append, truncate, flush, and fsync.
- Directories: create, enumerate, rename, and remove.
- Symbolic links: create, read, follow, rename, and unlink.
- Hard links: shared identity, persistent link counts, rename, and open-unlinked lifetime.
- FIFOs: persistent metadata with transport managed by the Linux kernel.
- Metadata: mode, uid, gid, birth time, ctime, mtime, and access time.
- Namespace operations preserve open descriptors across rename and unlink.
- Hard-linked paths report one inode number and share data, metadata, and page cache.
- File link counts equal namespace ObjectRefs; directory counts are two plus direct subdirectories.
- Final unlink reports zero links through open descriptors and defers object deletion until close.
- Multiple open handles observe committed non-overlapping writes.
- POSIX and OFD record locks are managed locally by the Linux VFS.
- `RENAME_NOREPLACE` is supported; exchange and whiteout rename modes are not.
- Names are case-sensitive and limited to 255 UTF-8 bytes per path component.
- Sparse files support logical sizes up to 9,223,372,036,854,775,807 bytes.
- Holes read as zero and do not allocate their logical length.
- Mode-zero `fallocate` and `posix_fallocate` provide persistent sparse range
  reservations that survive remount and are shared by hard links.

Linux mounts use `default_permissions`; the kernel enforces user access before
requests reach the filesystem. Each read, readlink, or readdir request observed
by the daemon attempts to persist a newer atime without changing ctime. Linux
page-cache hits do not generate FUSE requests, so those accesses cannot update
the persisted atime while cached I/O remains enabled. An atime persistence
failure does not turn an otherwise successful read into an error.

## Persistence

`fsync` commits file data through littlefs and synchronizes the container file.
After a successful `fsync`, terminating the mount process must not lose the
committed data. A clean unmount synchronizes and closes the littlefs volume.

Link counts are not stored in object metadata. Each mount rebuilds the in-memory
`ObjectId` link-count index by scanning namespace ObjectRefs, which remain the
persistent authority. Legacy images whose symlinks use file-kind ObjectRefs
remain readable because node behavior comes from persisted object metadata.

FIFO objects persist type, mode, ownership, and timestamps. Linux VFS manages
their blocking and byte transport; Zettide does not store FIFO payload data.

The `check` command validates both container headers, mounts the filesystem, and
traverses allocated blocks. It is a structural readability check, not a repair
tool or a complete offline fsck.

## Unsupported Operations

The Linux adapter does not currently implement:

- Arbitrary extended attributes
- Device and socket nodes
- Nonzero `fallocate` modes
- `copy_file_range`
- `flock`
- `RENAME_EXCHANGE` and `RENAME_WHITEOUT`

Callers must receive a stable unsupported-operation error instead of silent
success for these operations.

## Test Gates

- `test-unit` covers codecs, geometry, block boundaries, and error handling.
- `test-image` uses real sparse container files and always reopens persisted data.
- `test-cli` runs the emitted executable and validates exit behavior.
- `test-fault` injects deterministic block synchronization failures.
- `test-fuse` performs real syscalls, a forced daemon crash, and 20 mount cycles.
- `test-dufs` covers HTTP read/write, read-only serving, persistence, signal
  inheritance, active-request shutdown, child exit, and private-mount cleanup.
- `test-libfuse` runs the applicable cases from libfuse's syscall test suite.
- `test-fsx` runs deterministic buffered and mmap read, write, and truncate workloads.
- `test-cross` compiles the portable core and CLI for x86_64 Windows GNU.

The required FUSE gate must not skip because `/dev/fuse` or helper programs are
missing. The auto mode may skip and prints the missing capability.
