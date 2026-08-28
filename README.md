# Zettide

Zettide is an experimental storage engine for single-node, multi-physical-disk
storage ownership. Tier 1 covers both a same-host virtualization deployment and
a dedicated single storage node. BlobFilesystem provides filesystem data, while
Catalog Volumes provide block data; both are designed to use Pools assembled
from independent physical disks.

The current multi-disk filesystem path is BlobFilesystem on a Linux raw-disk
Blob Pool through the foreground FUSE3 adapter. A standalone regular Blob file
is also supported. Catalog Pools feed the partial managed SPDK endpoint path and
are not mounted as filesystems. The core cross-compiles for Windows; the native
WinFsp dispatcher remains an explicit, conditionally compiled integration
boundary.

## Repository Layout

This is the single source repository for the Zettide storage project. The
former `zettide-control`, `zettide-cawfs`, and `zettide-node-protocol`
repositories retain their histories here as merged directory trees:

| Path | Role |
| --- | --- |
| `services/zettide/` | Pool, Volume, BlobFilesystem, frontend, and endpoint implementation |
| `services/control/` | Raft-replicated metadata and cluster coordination |
| `services/csi/` | CSI node service and container image |
| `services/nfs-fsal/` | NFS-Ganesha FSAL adapter |
| `libs/txfs/` | Conditional-write transaction engine for shared writable filesystems |
| `libs/data-service-contracts/` | Shared data-service API and authority/fencing contracts |
| `tests/` | Zig, C, shell, conformance, and integration tests |
| `tests/automation/` | Isolated uv/Ansible project for remote and hardware test automation |
| `benchmarks/` | Buildable benchmark entry points |
| `vendor/grpc-lite/` | Zig RPC runtime submodule |
| `vendor/raftz/` | Consensus runtime submodule |
| `vendor/spdk/` | Managed SPDK fork submodule |

`qtr` and `etz` are intentionally outside this storage repository and are not
part of its bootstrap, build, test, or update lifecycle. See
[`docs/repository-migration.md`](docs/repository-migration.md) for the imported
history map and publication order.

## Capability Stages

Tier 1 is the single-node storage takeover milestone. It requires all four
baseline frontends against the appropriate Pool-backed data model, without
requiring storage-node replication:

| Frontend | Data model | Tier 1 role | Current status |
| --- | --- | --- | --- |
| NVMf over TCP or RDMA | Catalog Volume | Preferred block publication | Partial: endpoint daemon and exports exist, but there is no qtr-managed end-to-end path |
| iSCSI | Catalog Volume | Block fallback | Target |
| NFS | BlobFilesystem | Network filesystem publication | Partial: NFSv3 FSAL opens a standalone target or one Pool member; it cannot assemble a multi-member Pool |
| FUSE | BlobFilesystem | Local and same-host filesystem mount | Current multi-disk path |

Virtualization is a first-class Tier 1 consumer. A native qtr backend is required
for Tier 1; Proxmox VE is a first-class follow-up target but does not block the
Tier 1 milestone. CSI is a secondary, non-blocking target: block volumes use
NVMf or iSCSI, and filesystem volumes use NFS or FUSE.

The later tiers remain cumulative:

| Tier | Additional capability |
| --- | --- |
| Tier 2 | Dynamic Pool membership, recoverable online capacity/protection migration, multi-Volume service governance, attachment governance, and fuller platform lifecycle |
| Tier 3 | Cross-node replication, fencing, storage failover, repair, and caller-directed republication |

Tier 3 control metadata foundations exist in the integrated `services/control/` module,
but the distributed data path does not.

The current raw Pool product commands accept one unprotected device, three
replicated devices, or 3 through 12 `scheduled-replicated` devices. The format
and libraries can represent dynamic membership, a multi-Volume catalog, catalog
extent mappings, and protection metadata, but online capacity expansion and
protection-policy migration are not connected to a product lifecycle yet.

A regular file, a synthetic or loop-backed member, or one physical disk remains
useful for development and qualification, but none satisfies Tier 1 completion.
The raw Pool completion gate requires multiple Pool members on independent
physical disks, with Catalog Volumes qualified through NVMf and iSCSI and
BlobFilesystem qualified through NFS and FUSE.

Linux SPDK support includes an optional foreground endpoint daemon with a
versioned owner-only Unix control API and persistent desired state. It composes
the managed SPDK runtime, catalog Volume backend, custom bdev provider, and
standard NVMf TCP/RDMA and vhost-user-blk export lifecycles. These are endpoint
and export primitives, not a complete consumer-bound Publication API: consumer
identity, access-generation fencing, a protocol-neutral expected-identity
result, qtr-side identity validation, managed attachment, and restart
reconciliation are not implemented. The existing endpoint does derive stable
NQN and NVMe serial values. The iSCSI target lifecycle is also not implemented.

## Requirements

- Zig 0.16.0 (managed by the root `mise.toml`)
- Linux: libfuse3 development files for mounting support
- Optional HTTP/WebDAV serving: `dufs` on `PATH` (tested with 0.46.0)
- Optional Linux SMB3 feasibility tests: Samba server and client tools
- Linux file-backed Volumes use io_uring writeback with a synchronous POSIX foreground lane
- Linux raw-disk Pools use io_uring when available, with an automatic POSIX fallback
- Windows: WinFsp developer package and runtime for mounting support

## Build

Initialize the dependency submodules and run the unified build through mise:

```sh
mise trust
mise install
mise run bootstrap
mise run build
mise run test
mise run check
```

The equivalent focused Zig gates include:

```sh
zig build
zig build test
zig build test-control
zig build test-txfs
zig build ci
```

Build the Linux endpoint daemon against an SPDK pkg-config installation with:

```sh
PKG_CONFIG_PATH=vendor/spdk/build/lib/pkgconfig zig build -Dspdk=true
```

## Benchmarks

The filesystem operations benchmark uses zBench directly on BlobFilesystem with
temporary file-backed Blob targets. It excludes the mounted FUSE/VFS syscall path
as well as format, mount, setup, and cleanup time; backing-file syscalls remain
included. Run the representative optimized build with:

```sh
zig build bench-fs-ops -Doptimize=ReleaseFast -- \
  --iterations 100 --warmup 5
```

Use `--operation NAME` to select one workload. The available workloads are
`create`, `open`, `stat`, `read-readonly`, `read-writable-relatime`,
`read-partial`, `write-overwrite`, `rename`, and `remove`. The writable read
workload includes the default relatime checks; the read-only workload isolates
the data read path. Data workloads use a warmed fixed file and offset, so they
measure steady-state hot-path latency rather than cold or streaming I/O.
zBench reports average, standard deviation, range, and percentiles without a
performance pass/fail threshold. Run with `--help` for all options.

The BlobDevice benchmark measures aligned sequential I/O without BlobStore,
object metadata, or FUSE:

```sh
zig build build-bench-blob-device -Doptimize=ReleaseSafe
./zig-out/bin/zettide-blob-device-benchmark \
  --operation write --path /mnt/data/blob-device.bin --size 64GiB
```

BlobStore and BlobObject benchmarks add immutable blob framing and COW object
maps respectively:

```sh
zig build bench-blob-store -Doptimize=ReleaseFast -- \
  --operation write --path /mnt/data/blob-store.bin --size 64GiB
zig build bench-blob-object -Doptimize=ReleaseFast -- \
  --operation write --path /mnt/data/blob-object.bin --size 64GiB
```

`bench-blob-metadata-map` measures incremental filesystem metadata-map updates.
Run each benchmark with `--help` for its complete workload and transport options.

## Tests

```sh
zig build test-unit
zig build test-cli
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
zig build test-nfs-ganesha -Dnfs-ganesha-tests=required \
  -Dganesha-build-dir=/path/to/ganesha-build
zig build test-posix-baseline -Dfuse-tests=required
zig build test-posix-quick -Dfuse-tests=required -Dexternal-tests=required
zig build test-libfuse -Dexternal-tests=required
zig build test-fsx -Dexternal-tests=required
zig build test-fio -Dexternal-tests=required
zig build test-external -Dexternal-tests=required
zig build test-posix-privileged -Dprivileged-tests=required
zig build -j1 test-posix-nightly -Dfuse-tests=required -Dexternal-tests=required -Dprivileged-tests=required
zig build ci
```

`zig build test` runs the portable unit, CLI, control-plane, and TxFS suites. FUSE tests
perform real Linux syscalls and require writable `/dev/fuse`, `fusermount3`,
and `mountpoint`. Use `-Dfuse-tests=auto` to skip them when those capabilities
are unavailable.

These commands are component and frontend gates, not proof that the Tier 1
frontend contract is complete. The FUSE tests cover the current frontend, while
separate raw Pool profiles exercise Pool-backed paths with physical, loop, or
synthetic members. The local NFS-Ganesha gate uses a standalone regular-file
target, while the remote physical-Pool profile uses one Pool member; neither
assembles a multi-member Pool. The SPDK and NVMf gates cover endpoint and export
pieces without a qtr-managed end-to-end workflow. There is no iSCSI product gate
yet.

The optional Linux SPDK link check consumes a separately built SPDK tree through
its generated pkg-config metadata. For a sibling SPDK checkout built with shared
libraries, run:

```sh
PKG_CONFIG_PATH=vendor/spdk/build/lib/pkgconfig \
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

`test-nfs-ganesha` rebuilds `FSAL_ZETTIDE` in a separately configured pinned
NFS-Ganesha V13 tree, starts an isolated loopback NFSv3 export on temporary
ports, and mounts it through the Linux NFS client. This is a partial frontend
gate over a standalone regular-file target, not multi-disk NFS qualification.
The remote physical-Pool profile separately exercises one Pool member. It verifies
stable file IDs, hard links, symlinks, rename, truncate, persistence across a
server restart, and read-only reopening. It requires mount tools, rpcbind,
passwordless sudo, and `-Dganesha-build-dir` pointing to the build described in
`services/nfs-fsal/README.md`.

`test-fio` runs deterministic CRC32C verification over buffered synchronous I/O
to small files and multi-chunk sequential and random files. It verifies every
write on the live mount, cleanly unmounts the file-backed image, runs `check`,
remounts it, and verifies the complete data set from a separate fio process.
The gate requires the `fio` executable and runs on pushes and as part of
`test-posix-nightly`, not the pull-request quick gate. Set `ZETTIDE_FIO` to
select a non-default executable.

The privileged and nightly gates use pinned upstream suites prepared by an
explicit networked step. Test execution itself never downloads dependencies:

```sh
bash tests/external/prepare.sh
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
zettide format workspace.blob --size 16GiB --name-profile portable-v1
zettide info workspace.blob
zettide check workspace.blob
mkdir workspace
zettide mount workspace.blob workspace
# From another terminal:
zettide unmount workspace

# Alternatively, serve through the external dufs frontend until interrupted.
zettide serve dufs workspace.blob -- -A -b 127.0.0.1 -p 5000
```

Mounts use relatime by default. Pass `--noatime` to disable automatic
access-time updates.
Pass `--read-only` to open the Blob filesystem read-only.
Pass `--metrics` to print FUSE operation counters after a clean unmount.
Blob Pool mounts print aggregate Pool transport counters; standalone Blob file
mounts expose FUSE counters only.

`format` creates a standalone BlobFilesystem target in a regular file. For a
new file, `--size` is required, must be at least 2 MiB, and must be aligned to
1 MiB. An existing regular file requires a second invocation with the
scan-bound confirmation token:

```sh
truncate -s 16GiB workspace.blob
zettide format workspace.blob --name-profile portable-v1
zettide format workspace.blob --name-profile portable-v1 --confirm <token>
```

Formatting replaces the filesystem but does not securely erase every old data
block. The confirmation token binds the target identity, geometry, path, name
profile, and complete content digest observed by the plan. The selected name
profile and current Linux UID/GID for the root directory are persisted.
Standalone Blob targets support Linux FUSE mount, read-only mount, FUSE metrics,
`info`, `check`, and `serve dufs`. They do not support labels, block devices,
Pool transport metrics, encryption, or Windows mounts.

The removed `create`, `key`, `--filesystem`, `--encrypt`, key-file,
passphrase, redo-journal, and `pool initialize` interfaces are not product
commands. A regular file carrying `LFSDRV2` in either header slot is recognized
only to return `UnsupportedLegacyFormat`; it is not opened or converted.

`serve dufs` creates a private FUSE mount, starts the `dufs` executable found on
`PATH`, and removes the mount when either process exits. Dufs keeps its own
read-only defaults; pass options after `--` to enable uploads, authentication,
TLS, or other dufs behavior. `--read-only` also opens and mounts the underlying
Zettide target read-only:

```sh
zettide serve dufs workspace.blob --read-only -- -b 127.0.0.1 -p 5000
```

Linux raw-disk Pools currently support exactly one unprotected device or three
replicated devices; `scheduled-replicated` accepts 3 through 12 devices.
Creation destroys all data on the explicitly listed whole devices and requires
the confirmation token produced by the full-device scan:

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

`pool plan-create` and `pool create` always provision Blob data mode and persist
the BlobFilesystem root before reporting success. There is no backend selector
or separate initialize step. `pool mount` accepts Blob mode only and determines
the mode from member headers. Use `zettide pool inspect --device ...` to report
the persisted data mode, authority, topology, layout, data policy, member state,
and Blob mountability.

Catalog is the separate block data mode used by the managed SPDK endpoint path.
It stores Catalog Volumes and extent mappings and is not accepted by filesystem
mount commands. Headers without a Blob or Catalog marker are reported as
`legacy_unsupported` and rejected. Blob Pools do not migrate legacy Pools and do
not yet support encryption, erasure coding, garbage collection, online
expansion, or protection changes.

## Format limits

- File names are at most 255 UTF-8 bytes.
- Sparse files are supported up to 9,223,372,036,854,775,807 bytes.
- File name matching is case-sensitive on every platform.
- Standalone Blob files require regular-file storage; raw devices use Pool
  commands.
- `LFSDRV2` regular-file containers are unsupported and rejected after format
  recognition.

The supported filesystem behavior and explicit exclusions are documented in
`docs/fs-semantics.md`.

The persisted cross-platform name contract is documented in
`docs/portable-name-profile.md`.

The target POSIX.1-2024 filesystem semantics and completion criteria are
defined in `docs/posix-profile.md`.

utf8proc is licensed under MIT and includes Unicode-licensed generated data.
Its pinned source, Unicode version, and license are in `vendor/utf8proc`.

Vendored libfuse and xfstests test sources are GPL-2.0 and are only compiled as
test executables. Their source commits and licenses are recorded under `vendor/`.
Fetched pjdfstest, xfstests, and LTP source licenses and commits are recorded in
`tests/external/suites.tsv`.
