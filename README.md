# Zettide

Zettide is an experimental **single-node block storage system for virtual-machine
disks**, with its own Catalog/Volume engine and local multi-disk protection.
It can serve consumers on the same host or over a storage network. It does not
provide cross-node replication or storage-node failover.

> Zettide is not production-ready. Raw-disk provisioning is destructive, and
> managed VM attachment and concurrent multi-Volume publication remain incomplete.

## Scope

The product boundary is defined by
[ADR 0005](docs/decisions/0005-single-node-vm-block-storage.md). The supported
direction is Catalog block storage, Linux data-node composition, local recovery,
and a narrow host-facing block interface. NVMe/TCP is the intended primary
frontend.

The cluster controller, distributed Replica protocol, TxFS, CSI, and `zettidectl`
have been removed. Filesystem and additional block frontend code still present
during the transition is not a product commitment. See
[scope and implementation status](docs/architecture/zh-CN/00-scope-and-status.md).

## Repository

| Path | Responsibility |
| --- | --- |
| `libs/storage-engine/` | In-process storage engine, Pool/Member/Catalog/Volume, persistent formats, and local protection |
| `services/data-node/` | Local CLI, Linux adapters, endpoint lifecycle, and SPDK integration |
| `tests/` | Engine, local lifecycle, compatibility, and hardware-oriented validation |
| `vendor/` | Pinned external dependencies |

qtr, PVE, and etz are external projects, outside this repository's build and test
lifecycle.

## Development

Use `mise` for the pinned Zig, CMake, and Ninja toolchain. During the filesystem
removal transition, the existing CLI build still requires FUSE3 development
headers on Linux.

```sh
mise trust
mise install
mise run bootstrap
zig build
mise run dev
```

Before committing, run the regular non-incremental gates:

```sh
mise run test
mise run check
```

Focused boundaries:

```sh
zig build test-storage-engine
zig build test-data-node
zig build test-module-roots
zig build test-compatibility
```

The existing `zettide endpoint serve` path is retained for local block exports;
it requires an SPDK-enabled build. A successful local export is not proof of
managed VM attachment or multiple simultaneously published Volumes per Pool.

## Documentation

- [Documentation index](docs/README.md)
- [Architecture and current limits](docs/architecture/zh-CN/README.md)
- [Architecture decisions](docs/decisions/README.md)
- [Member/Pool format](docs/v3-format.md)
- [Multi-Volume Catalog format](docs/v3-multivolume-format.md)
- [Control rollover format](docs/v3-control-rollover-format.md)
