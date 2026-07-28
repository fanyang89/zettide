# Zettide

Zettide is an experimental cross-platform, single-file development volume
built on [littlefs](https://github.com/littlefs-project/littlefs). Containers
have a fixed logical capacity, can be sparse on the host filesystem, and reserve
format space for future authenticated encryption.

The project currently implements the portable container core and a foreground
Linux FUSE3 mount adapter. The core cross-compiles for Windows; the native
WinFsp dispatcher remains an explicit, conditionally compiled integration
boundary.

## Requirements

- Zig 0.16.0
- Linux: libfuse3 development files for mounting support
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

The Linux block-device gate uses a temporary loop device and requires
`losetup`, `blockdev`, `mkfs.ext4`, mount tools, and passwordless `sudo`. It
never targets an existing physical device.

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
mkdir workspace
zettide mount workspace.ddv workspace
# From another terminal:
zettide unmount workspace
```

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
