# DevDrive

DevDrive is an experimental cross-platform, single-file development volume
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
zig build test-fuse -Dfuse-tests=required
zig build ci
```

`zig build test` runs the portable unit, image, and CLI suites. FUSE tests
perform real Linux syscalls and require writable `/dev/fuse`, `fusermount3`,
and `mountpoint`. Use `-Dfuse-tests=auto` to skip them when those capabilities
are unavailable.

## Usage

```sh
devdrive create workspace.ddv --size 16GiB --label Workspace
devdrive info workspace.ddv
devdrive check workspace.ddv
mkdir workspace
devdrive mount workspace.ddv workspace
# From another terminal:
devdrive unmount workspace
```

## Format limits

- File names are at most 255 UTF-8 bytes.
- Individual files are at most 2,147,483,647 bytes.
- File name matching is case-sensitive on every platform.
- Version 1 containers are not encrypted.

The supported filesystem behavior and explicit exclusions are documented in
`docs/fs-semantics.md`.

littlefs is licensed under BSD-3-Clause. Its pinned source and license are in
`vendor/littlefs`.
