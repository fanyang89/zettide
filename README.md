# Zettide

Zettide is an experimental storage engine. Its current user-facing path mounts
a [littlefs](https://github.com/littlefs-project/littlefs) filesystem from a
sparse container file or an explicitly selected Linux raw-disk Pool.

The project currently implements the portable container core and a foreground
Linux FUSE3 mount adapter. The core cross-compiles for Windows; the native
WinFsp dispatcher remains an explicit, conditionally compiled integration
boundary.

## Capability Stages

Zettide is being developed as three cumulative storage tiers:

| Tier | Product capability | Status |
| --- | --- | --- |
| Tier 1 | Mount a local filesystem backed by a container file or raw devices | Current Linux path; full POSIX-profile completion remains in progress |
| Tier 2 | Serve local catalog Volumes as blocks to qtr, with iSCSI as the first managed protocol | Local daemon, control API, and optional vhost-user-blk backend exist; iSCSI and qtr integration remain targets |
| Tier 3 | Replicate Volumes across storage nodes and republish them after a storage failure | Target; control metadata exists in `zettide-control`, but the distributed data path does not |

The current raw Pool product commands accept exactly one unprotected device or
three replicated devices. The format and libraries can represent dynamic
membership, a multi-Volume catalog, catalog extent mappings, and protection
metadata, but online capacity expansion and protection-policy migration are not
connected to a product lifecycle yet.

Linux SPDK support includes an optional foreground endpoint daemon with a
versioned owner-only Unix control API and persistent desired state. It composes
the managed SPDK runtime, catalog Volume backend, custom bdev provider, and
vhost-user-blk export lifecycle. The iSCSI export lifecycle and qtr attachment
reconciliation are not implemented yet.

## Requirements

- Zig 0.16.0
- Linux: libfuse3 development files for mounting support
- Optional HTTP/WebDAV serving: `dufs` on `PATH` (tested with 0.46.0)
- Optional Linux SMB3 feasibility tests: Samba server and client tools
- Linux raw-disk Pools: io_uring enabled by the kernel and execution sandbox
- Windows: WinFsp developer package and runtime for mounting support

## Build

```sh
zig build
zig build test
```

Build the Linux endpoint daemon against an SPDK pkg-config installation with:

```sh
PKG_CONFIG_PATH=../third_party/spdk/build/lib/pkgconfig zig build -Dspdk=true
```

## Benchmarks

The filesystem operations benchmark uses zBench on the `Volume` API with
temporary file-backed containers. It excludes the mounted FUSE/VFS syscall path
as well as format, mount, setup, and cleanup time; backing-file syscalls remain
included. Run the representative optimized build with:

```sh
zig build bench-fs-ops -Doptimize=ReleaseFast -- \
  --iterations 100 --warmup 5
```

Use `--operation NAME` to select one workload. The available workloads are
`create`, `open`, `stat`, `read-readonly`, `read-writable-relatime`,
`write-overwrite`, `rename`, and `remove`. Writes are already durable when the
internal littlefs files close, so there is no separate sync-write workload. The
writable read workload includes the default relatime checks; the
read-only workload isolates the data read path. Data workloads use a warmed
fixed file and offset, so they measure steady-state hot-path latency rather than
cold or streaming I/O. zBench reports average, standard deviation, range, and
percentiles without a performance pass/fail threshold. Run with `--help` for all
options.

## Tests

```sh
zig build test-unit
zig build test-image
zig build test-cli
zig build test-fault
zig build test-cross
zig build test-linux-block -Dblock-tests=required
zig build test-spdk-link
zig build test-spdk-endpoint
zig build test-spdk-dispatcher
zig build test-spdk-provider
zig build test-spdk-vhost-blk-controller
zig build test-spdk-daemon -Dspdk=true
zig build test-spdk-storage
zig build test-fuse -Dfuse-tests=required
zig build test-dufs -Dfuse-tests=required
zig build test-smb3-linux -Dsmb3-tests=required
zig build test-posix-baseline -Dfuse-tests=required
zig build test-posix-quick -Dfuse-tests=required -Dexternal-tests=required
zig build test-libfuse -Dexternal-tests=required
zig build test-fsx -Dexternal-tests=required
zig build test-external -Dexternal-tests=required
zig build test-posix-privileged -Dprivileged-tests=required
zig build -j1 test-posix-nightly -Dfuse-tests=required -Dexternal-tests=required -Dprivileged-tests=required
zig build ci
```

`zig build test` runs the portable unit, image, and CLI suites. FUSE tests
perform real Linux syscalls and require writable `/dev/fuse`, `fusermount3`,
and `mountpoint`. Use `-Dfuse-tests=auto` to skip them when those capabilities
are unavailable.

The optional Linux SPDK link check consumes a separately built SPDK tree through
its generated pkg-config metadata. For a sibling SPDK checkout built with shared
libraries, run:

```sh
PKG_CONFIG_PATH=../third_party/spdk/build/lib/pkgconfig \
zig build test-spdk-link
```

`test-spdk-link` validates headers and shared-library loading only. The focused
SPDK gates exercise managed runtime, bdev, provider, storage, and vhost
lifecycles. `test-spdk-daemon` starts the product daemon without configured
Pools and verifies graceful signal shutdown; it does not bind storage devices.

The Linux block-device gate uses temporary loop devices and requires `losetup`,
`blockdev`, `mkfs.ext4`, `fusermount3`, `mountpoint`, a writable `/dev/fuse`,
`timeout`, mount tools, and passwordless `sudo`. It never targets an existing
physical device.

The external gates compile pinned source snapshots from libfuse and xfstests
stored under `vendor/`. `test-libfuse` runs the syscall cases that match the
declared Zettide semantics. `test-fsx` runs deterministic 10,000-operation
buffered and mmap I/O workloads with two seeds. Set `ZETTIDE_FSX_OPS=100000`
for a longer stress run. These gates have the same Linux FUSE requirements as `test-fuse`
and are not part of the default `test` or `ci` targets.

`test-smb3-linux` starts an isolated Samba instance on a temporary high port
over a private Zettide FUSE mount. It requires authenticated, signed, encrypted
SMB3 and verifies write, rename, read-only access, unmount, and persistence. The
gate does not install a product SMB service or modify the system Samba
configuration. Its current scope and exclusions are documented in
`docs/smb3-profile.md`.

The privileged and nightly gates use pinned upstream suites prepared by an
explicit networked step. Test execution itself never downloads dependencies:

```sh
bash test/external/prepare.sh
zig build -j1 test-posix-nightly \
  -Dfuse-tests=required -Dexternal-tests=required -Dprivileged-tests=required
```

Passwordless `sudo` is used only by runners that require multiple identities.
In `auto` mode, missing FUSE, root, or prepared-suite prerequisites skip that
runner. In `required` mode, the same condition fails the gate. Full setup,
pins, manifests, and log controls are documented in
`docs/posix-nightly.md`.

## Usage

```sh
zettide format workspace.ddv --size 16GiB --label Workspace

# Legacy container creation remains supported.
zettide create legacy.ddv --size 16GiB --label Legacy
zettide info legacy.ddv
zettide check legacy.ddv
zettide device inspect /dev/disk/by-id/example
mkdir workspace
zettide mount workspace.ddv workspace
# From another terminal:
zettide unmount workspace

# Alternatively, serve through the external dufs frontend until interrupted.
zettide serve dufs workspace.ddv -- -A -b 127.0.0.1 -p 5000
```

Mounts use relatime by default. Pass `--noatime` to disable automatic
access-time updates.

`format` creates a single-member unprotected v3 target. For a new regular file,
`--size` is required and specifies the total backing-file length. The length
must be at least 3 MiB and aligned to 1 MiB. Existing regular files and Linux
block devices require a second invocation with the scan-bound confirmation
token:

```sh
zettide format /dev/disk/by-id/example --label Workspace
zettide format /dev/disk/by-id/example --label Workspace --confirm <token>
```

Formatting replaces the filesystem but does not securely erase every old data
block. The confirmation token binds the target identity, geometry, path, label,
and complete content digest observed by the plan.

`serve dufs` creates a private FUSE mount, starts the `dufs` executable found on
`PATH`, and removes the mount when either process exits. Dufs keeps its own
read-only defaults; pass options after `--` to enable uploads, authentication,
TLS, or other dufs behavior. `--read-only` also opens and mounts the underlying
Zettide target read-only:

```sh
zettide serve dufs workspace.ddv --read-only -- -b 127.0.0.1 -p 5000
```

Linux raw-disk Pools currently support exactly one unprotected device or three
replicated devices. Creation destroys all data on the explicitly listed whole
devices and requires the confirmation token produced by the full-device scan:

```sh
zettide pool plan-create \
  --device /dev/disk/by-id/disk-a \
  --device /dev/disk/by-id/disk-b \
  --device /dev/disk/by-id/disk-c \
  --profile replicated --label Workspace
zettide pool create \
  --device /dev/disk/by-id/disk-a \
  --device /dev/disk/by-id/disk-b \
  --device /dev/disk/by-id/disk-c \
  --profile replicated --label Workspace \
  --confirm <token>
mkdir workspace
zettide pool mount workspace \
  --device /dev/disk/by-id/disk-a \
  --device /dev/disk/by-id/disk-b \
  --device /dev/disk/by-id/disk-c
```

Use `zettide pool inspect --device ...` to inspect authority and mountability.
An interrupted empty-volume initialization exposes a Pool-bound recovery token;
pass it to `zettide pool initialize --device ... --confirm <token>`.

## Format limits

- File names are at most 255 UTF-8 bytes.
- Sparse files are supported up to 9,223,372,036,854,775,807 bytes.
- File name matching is case-sensitive on every platform.
- Version 2 containers are not encrypted.
- `format` writes a v3 single-member target; legacy version 2 containers remain
  readable.

The supported filesystem behavior and explicit exclusions are documented in
`docs/fs-semantics.md`.

The not-yet-persisted cross-platform name contract is documented in
`docs/portable-name-profile.md`.

The target POSIX.1-2024 filesystem semantics and completion criteria are
defined in `docs/posix-profile.md`.

littlefs is licensed under BSD-3-Clause. Its pinned source and license are in
`vendor/littlefs`.

utf8proc is licensed under MIT and includes Unicode-licensed generated data.
Its pinned source, Unicode version, and license are in `vendor/utf8proc`.

Vendored libfuse and xfstests test sources are GPL-2.0 and are only compiled as
test executables. Their source commits and licenses are recorded under `vendor/`.
Fetched pjdfstest, xfstests, and LTP source licenses and commits are recorded in
`test/external/suites.tsv`.
