# Filesystem Semantics

This document defines the behavior covered by the DevDrive test suites. Linux
FUSE is the only mount adapter currently implemented. Windows builds verify the
portable container core, but do not yet provide a WinFsp filesystem.

## Supported Operations

- Regular files: create, open, read, write, append, truncate, flush, and fsync.
- Directories: create, enumerate, rename, and remove.
- Symbolic links: create, read, follow, rename, and unlink.
- Metadata: mode, uid, gid, birth time, ctime, mtime, and relatime atime.
- Namespace operations preserve open descriptors across rename and unlink.
- Multiple open handles observe committed non-overlapping writes.
- `RENAME_NOREPLACE` is supported; exchange and whiteout rename modes are not.
- Names are case-sensitive and limited to 255 UTF-8 bytes per path component.
- Sparse files support logical sizes up to 9,223,372,036,854,775,807 bytes.
- Holes read as zero and do not allocate their logical length.

Linux mounts use `default_permissions`; the kernel enforces user access before
requests reach the filesystem. Internally, some read operations may require a
metadata write to persist relatime.

## Persistence

`fsync` commits file data through littlefs and synchronizes the container file.
After a successful `fsync`, terminating the mount process must not lose the
committed data. A clean unmount synchronizes and closes the littlefs volume.

The `check` command validates both container headers, mounts the filesystem, and
traverses allocated blocks. It is a structural readability check, not a repair
tool or a complete offline fsck.

## Unsupported Operations

The Linux adapter does not currently implement:

- Hard links
- Arbitrary extended attributes
- Device nodes and FIFOs
- `fallocate`
- `copy_file_range`
- Record locks and `flock`
- `RENAME_EXCHANGE` and `RENAME_WHITEOUT`

Callers must receive a stable unsupported-operation error instead of silent
success for these operations.

## Test Gates

- `test-unit` covers codecs, geometry, block boundaries, and error handling.
- `test-image` uses real sparse container files and always reopens persisted data.
- `test-cli` runs the emitted executable and validates exit behavior.
- `test-fault` injects deterministic block synchronization failures.
- `test-fuse` performs real syscalls, a forced daemon crash, and 20 mount cycles.
- `test-libfuse` runs the applicable cases from libfuse's syscall test suite.
- `test-fsx` runs deterministic randomized read, write, and truncate workloads.
- `test-cross` compiles the portable core and CLI for x86_64 Windows GNU.

The required FUSE gate must not skip because `/dev/fuse` or helper programs are
missing. The auto mode may skip and prints the missing capability.
