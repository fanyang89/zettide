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

The cluster controller, distributed Replica protocol, TxFS, CSI, `zettidectl`,
and the BlobFilesystem/FUSE/NFS/dufs product line have been removed. Additional
block frontends still present during the transition are not a product commitment. See
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

Use `mise` for the pinned Zig, CMake, and Ninja toolchain. The default build does
not require FUSE, Unicode normalization libraries, a cluster, or an SPDK runtime.

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
zig build build-spdk-tests
```

The existing `zettide endpoint serve` path is retained for local block exports;
it requires an SPDK-enabled build. A successful local export is not proof of
managed VM attachment or multiple simultaneously published Volumes per Pool.

The CLI now exposes `device inspect`, `pool plan-create`, `pool create`,
`pool inspect`, and `endpoint serve`. Pool creation uses Catalog mode: one
unprotected device or three replicated devices. It creates Pool metadata only,
not an initialized Catalog or Volume. Old filesystem commands and
`--name-profile`/`scheduled-replicated` creation options are rejected. A new
scan-bound confirmation token is required; old creation tokens cannot be reused.

No automatic conversion of existing Blob files or Pools is provided. Retained
format identities let diagnostics identify old media without interpreting it as
a Catalog. See [block safety](docs/block-safety.md).

## Documentation

- [Documentation index](docs/README.md)
- [Architecture and current limits](docs/architecture/zh-CN/README.md)
- [Architecture decisions](docs/decisions/README.md)
- [Member/Pool format](docs/v3-format.md)
- [Multi-Volume Catalog format](docs/v3-multivolume-format.md)
- [Control rollover format](docs/v3-control-rollover-format.md)
