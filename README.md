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
| Tier 1 | Mount a local filesystem backed by a container file or raw devices | Current on Linux through foreground FUSE |
| Tier 2 | Serve local catalog Volumes as blocks to qtr, with iSCSI as the first managed protocol | Target; no daemon, iSCSI target, or qtr integration exists yet |
| Tier 3 | Replicate Volumes across storage nodes and republish them after a storage failure | Target; control metadata exists in `zettide-control`, but the distributed data path does not |

The current raw Pool product commands accept exactly one unprotected device or
three replicated devices. The format and libraries can represent dynamic
membership, a multi-Volume catalog, catalog extent mappings, and protection
metadata, but online capacity expansion and protection-policy migration are not
connected to a product lifecycle yet.

Linux SPDK support is also library-level rather than a storage service. The
repository contains a managed SPDK runtime, SPDK bdev access, an NVMe-oF
initiator wrapper, an asynchronous custom bdev provider, a catalog Volume
backend, and vhost-user-blk export lifecycle. These paths have focused tests,
but there is no long-running Zettide daemon, stable management API, iSCSI
export lifecycle, or qtr attachment reconciliation.

## Requirements

- Zig 0.16.0
- Linux: libfuse3 development files for mounting support
- Linux raw-disk Pools: io_uring enabled by the kernel and execution sandbox
- Windows: WinFsp developer package and runtime for mounting support

## Build

```sh
zig build
zig build test
```

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
zig build test-spdk-storage
zig build test-fuse -Dfuse-tests=required
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

`test-spdk-link` validates headers and shared-library loading only. The other
SPDK gates exercise the managed runtime and focused bdev, provider, storage, or
vhost controller lifecycles in isolated test configurations. They do not form
a product daemon or bind an operator's storage devices.

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
zettide create workspace.ddv --size 16GiB --label Workspace
zettide info workspace.ddv
zettide check workspace.ddv
zettide device inspect /dev/disk/by-id/example
mkdir workspace
zettide mount workspace.ddv workspace
# From another terminal:
zettide unmount workspace
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

The supported filesystem behavior and explicit exclusions are documented in
`docs/fs-semantics.md`.

The target POSIX.1-2024 filesystem semantics and completion criteria are
defined in `docs/posix-profile.md`.

littlefs is licensed under BSD-3-Clause. Its pinned source and license are in
`vendor/littlefs`.

Vendored libfuse and xfstests test sources are GPL-2.0 and are only compiled as
test executables. Their source commits and licenses are recorded under `vendor/`.
Fetched pjdfstest, xfstests, and LTP source licenses and commits are recorded in
`test/external/suites.tsv`.
