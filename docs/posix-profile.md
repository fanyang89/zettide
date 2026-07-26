# POSIX.1-2024 Filesystem Profile

This document defines the filesystem semantics that the DevDrive Linux FUSE
adapter must provide before it can be described as POSIX-compatible. It is a
project conformance profile, not an operating-system POSIX certification.

## Scope

- The profile applies only to the Linux FUSE mount adapter.
- The reference standard is POSIX.1-2024, Issue 8.
- Required behavior must work through mounted filesystem syscalls, not only the
  portable Volume API.
- A required test may not be skipped, marked unsupported, or accepted as a
  known failure.
- Where POSIX permits multiple errors, the test manifest records the accepted
  set explicitly.

## Required Semantics

- Regular files, directories, symbolic links, hard links, and FIFOs.
- Stable file identity and accurate link counts, including open unlinked files.
- Atomic link, unlink, and rename namespace behavior.
- Open file descriptions shared by `dup()` and `fork()`, including offsets and
  status flags such as dynamically changed `O_APPEND`.
- Buffered read and write, `MAP_SHARED`, `MAP_PRIVATE`, `msync()`, truncate, and
  mmap lifetime after close, rename, and unlink.
- Process-owned and open-file-description advisory record locks.
- Mode, ownership, umask, set-id clearing, setgid directory inheritance, and
  sticky-directory protection.
- atime advances without changing ctime for every read, readlink, and readdir
  request delivered to the FUSE daemon; mtime and ctime follow POSIX mutation
  rules.
- `fsync()`, `fdatasync()`, directory synchronization, and crash recovery after
  a successful synchronization call.
- POSIX pathname resolution, component limits, required errors, sparse files,
  and coherent `stat()` and `statvfs()` results.

## Separate Profiles

The following interfaces are useful Linux or UNIX extensions but do not gate
this base filesystem profile:

- Extended attributes and POSIX ACLs
- `flock()`
- `O_TMPFILE`
- `copy_file_range()`
- Linux-specific `fallocate()` modes other than mode zero
- `RENAME_EXCHANGE` and `RENAME_WHITEOUT`
- Device nodes

## Implementation Constraints

- The FUSE adapter uses one request-processing thread until object transactions
  gain object-level locking.
- Namespace ObjectRefs are the persistent source of truth for hard-link counts.
- File data and metadata are addressed by Object ID, so all links to one object
  must share one FUSE inode and one kernel page cache.
- Record locks are managed locally by the Linux VFS; the adapter does not
  negotiate remote lock capabilities.
- The conformance mount uses cached I/O. Linux does not send a FUSE request for
  a page-cache hit and libfuse does not receive an implicit atime `setattr`, so
  persisted atime cannot advance for those unobservable accesses. Pure cache
  hits are an explicit profile exception; direct I/O is not used to emulate
  them because it would remove the required shared page cache and writeback
  behavior.

## Conformance Gates

`test-posix-quick` is the required pull-request gate. `test-posix-nightly`
contains privileged pjdfstest cases, selected xfstests generic cases, mmap
stress, fault injection, and crash recovery. `test-posix-soak` increases seeds,
operation counts, and concurrent lock and namespace workloads.

`test-posix-privileged` covers sticky directories, ownership changes, set-id
clearing, and setgid inheritance using multiple real Linux identities. The
nightly selection and every intentional non-applicable case are recorded as
exact case IDs in the TSV manifests under `test/external/`; wildcard and group
exclusions are not accepted.

The profile is complete only when every required manifest entry executes and
passes in Debug and ReleaseSafe builds with no required skips.
