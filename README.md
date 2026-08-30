# Zettide

Zettide is an experimental storage platform for single-node, multi-disk storage
ownership and the control-plane foundations required for future distributed
storage. It provides filesystem storage through **BlobFilesystem**, block
storage through **Catalog Volumes**, and explicit service boundaries for data
nodes, controllers, CSI, and NFS.

> [!WARNING]
> Zettide is under active development and is not production-ready. Raw-disk
> Pool creation is destructive, distributed data replication is incomplete,
> and several service lifecycles remain intentionally partial.

[Current status](#current-status) · [Quick start](#quick-start) ·
[Architecture](#architecture) · [Administration CLI](#administration-cli) ·
[Development](#development) · [Documentation](#documentation)

## Current status

The authoritative implementation summary is
[`docs/architecture/zh-CN/00-scope-and-status.md`](docs/architecture/zh-CN/00-scope-and-status.md).
The table below is only a concise entry point.

| Area | Status | What exists today |
| --- | --- | --- |
| Standalone Blob file | Current | Format, inspect, check, Linux FUSE mount, read-only mode, metrics, and external `dufs` serving |
| Raw-disk Blob Pool | Current | One unprotected member or three local scheduled replicas, safe planning, confirmation, inspection, and FUSE mount |
| NFSv3 | Partial | `FSAL_ZETTIDE` can open a standalone target or one Pool member; multi-member assembly is not implemented |
| Catalog block path | Partial | Multi-Volume Catalog, extent mappings, SPDK-backed NVMf/iSCSI exports, endpoint registry, and focused lifecycle tests |
| Controller | Foundation | Raft-replicated metadata, leader-local heartbeats, placement/authority state machines, and a production-wired leader reconciler for the partial DataService lifecycle |
| CSI | Partial | CSI Node service for the current FUSE path; dynamic provisioning and a CSI Controller service are not implemented |
| Distributed data plane | Foundation | Three-node file-backed control lifecycle reaches `ACTIVE` and restart failover advances the write epoch; reconciliation provisions one immutable canonical three-Member set, data nodes advertise separately bound authenticated Replica RPC endpoints, and a backend-neutral durable coordinator journal now preserves independently verifiable Ed25519 PREPARE/COMMIT evidence for one fixed two-witness decision and node-local restart retry; participant contracts now require independently verified signed certificates, and controller metadata pins generation-1 signing public keys and provisions canonical Member/Node/key trust sets; daemon private-key enrollment, signed Replica RPC payloads, production fanout, rotation, confidentiality, quorum success, repair, and managed publication remain future work |

“Current” means implementation and validation entry points exist, not that the
feature is production-ready. “Partial” means the full lifecycle is incomplete.

## Quick start

### Prerequisites

- Linux with FUSE3 development headers and the `fusermount3` runtime
- [`mise`](https://mise.jdx.dev/) for the pinned Zig, CMake, and Ninja toolchain
- Git submodules initialized by the bootstrap task

### Build

```sh
mise trust
mise install
mise run bootstrap
zig build
```

### Create and mount a standalone BlobFilesystem

```sh
./zig-out/bin/zettide format workspace.blob \
  --size 16GiB \
  --name-profile portable-v1
./zig-out/bin/zettide info workspace.blob
./zig-out/bin/zettide check workspace.blob
mkdir workspace
./zig-out/bin/zettide mount workspace.blob workspace

# From another terminal:
./zig-out/bin/zettide unmount workspace
```

Mounts use `relatime` by default. Use `--read-only`, `--noatime`, or `--metrics`
when required. Existing files and whole-device Pools use a scan-bound
confirmation token before destructive formatting; never point development
commands at a device containing data you need.

## Architecture

Zettide separates durable storage mechanics from product and protocol adapters:

```text
Hosts and consumers
  ├─ FUSE / NFS / CSI
  └─ NVMf / iSCSI / vhost-user-blk
            │
            ▼
services/data-node ── endpoint and publication adapters
            │
            ▼
libs/storage-engine ── Pool, Member, Blob, BlobFilesystem, Catalog, Volume

zettidectl ── gRPC ── services/controller ── Raft/WAL/snapshots
                           └─ control intent ──► data nodes (partial lifecycle)
```

### Storage models

- **BlobFilesystem** stores POSIX-style files and directories over standalone
  regular files or raw-disk Blob Pools.
- **Catalog** stores block Volumes and extent mappings for the managed SPDK path;
  it is not mountable as BlobFilesystem.

### Repository map

| Path | Responsibility |
| --- | --- |
| `libs/storage-engine/` | Backend-neutral Pool, Blob, BlobFilesystem, Catalog, format, and recovery primitives |
| `libs/data-service-contracts/` | Shared data-service authority, lease, and fencing contracts |
| `libs/txfs/` | Conditional-write transaction engine for shared writable filesystems |
| `services/data-node/` | Data-node composition, local CLI, endpoint lifecycle, FUSE, NFS, and SPDK adapters |
| `services/controller/` | Raft-replicated metadata and cluster coordination service |
| `services/cli/` | Go gRPC administration client (`zettidectl`) |
| `services/csi/` | CSI Node service and container image |
| `services/nfs-fsal/` | NFS-Ganesha FSAL adapter |
| `tests/` | Unit, integration, compatibility, conformance, and hardware-oriented gates |
| `vendor/` | Pinned external source dependencies, including `grpc-lite`, `raftz`, and SPDK |

`qtr` and `etz` are separate projects. This repository documents their storage
integration boundaries but does not build or test their implementations.

## Administration CLI

`zettidectl` manages controller resources and exposes read-only data-node
diagnostics:

```sh
cd services/cli
mise trust
mise install
mise run check
mkdir -p bin
go build -trimpath -o bin/zettidectl ./cmd/zettidectl

bin/zettidectl --endpoint 127.0.0.1:50051 controller pool list
bin/zettidectl --endpoint 127.0.0.1:50051 --output json controller volume list
bin/zettidectl --endpoint 127.0.0.1:50052 data-node holder identify
```

Connections use plaintext by default for local development. `--tls-ca` enables
server-authenticated TLS, and `--tls-server-name` overrides certificate hostname
verification. Replica allocation, fencing, recovery, and primary mutation RPCs
remain internal to controller reconciliation.

See [`services/cli/README.md`](services/cli/README.md) for the complete command
surface, protobuf generation, ID encoding, pagination, and TLS details.

## Development

Use the persistent incremental build during active development:

```sh
mise run dev
```

Run non-incremental gates before committing:

```sh
mise run test
mise run check
```

Useful focused Zig boundaries:

```sh
zig build test-storage-engine
zig build test-data-node
zig build test-compatibility
zig build test-module-roots
zig build test-controller
zig build test-txfs
```

The Go components have independent gates:

```sh
(cd services/cli && mise run check)
(cd services/csi && mise run check)
```

Use `zig build --help` to discover benchmark and specialized validation steps.
External and privileged profiles have explicit prerequisite policies and never
silently download dependencies during test execution.

## Documentation

| Topic | Entry point |
| --- | --- |
| Documentation index and authority rules | [`docs/README.md`](docs/README.md) |
| Current scope and maturity | [`docs/architecture/zh-CN/00-scope-and-status.md`](docs/architecture/zh-CN/00-scope-and-status.md) |
| System architecture | [`docs/architecture/zh-CN/README.md`](docs/architecture/zh-CN/README.md) |
| Architecture decisions | [`docs/decisions/README.md`](docs/decisions/README.md) |
| Storage formats | [`docs/v3-format.md`](docs/v3-format.md), [`docs/v3-multivolume-format.md`](docs/v3-multivolume-format.md) |
| Filesystem and naming semantics | [`docs/fs-semantics.md`](docs/fs-semantics.md), [`docs/portable-name-profile.md`](docs/portable-name-profile.md) |
| POSIX and nightly validation | [`docs/posix-profile.md`](docs/posix-profile.md), [`docs/posix-nightly.md`](docs/posix-nightly.md) |
| Security boundaries | [`docs/architecture/zh-CN/10-security.md`](docs/architecture/zh-CN/10-security.md) |
| Evolution roadmap | [`docs/architecture/zh-CN/11-evolution-roadmap.md`](docs/architecture/zh-CN/11-evolution-roadmap.md) |

Component-specific build and operation notes live in each component's own
`README.md`.
