# Zettide Data Node

`services/data-node/` owns local VM block storage composition: Linux adapters,
the operator CLI, endpoint desired-state recovery, and SPDK block exports. It
consumes the public `zettide_storage` module and must not import engine sources
through cross-directory relative paths.

The product scope is [ADR 0005](../../docs/decisions/0005-single-node-vm-block-storage.md):
single-node storage with local multi-disk protection, not a distributed service.
The controller agent, DataService/Replica RPC daemon, remote write participants,
and cross-node lease/fencing machinery have been removed. No controller is
required to build or use the existing local endpoint path.

`zettide endpoint serve` retains the local endpoint daemon and owner-only Unix
control API. The registry persists desired endpoints and composes Catalog
exports through SPDK. NVMe/TCP is the primary direction; iSCSI, RDMA, and vhost
remain transitional implementations.

Important limits:

- One writable Pool has one process owner.
- The registry currently permits one endpoint per Pool, not simultaneous
  multi-Volume publication from one Pool.
- Existing exports are not a complete managed VM attachment lifecycle.
- Local protection does not imply degraded writes, online rebuild, or node HA.
- Filesystem/FUSE/NFS/dufs code and commands have been removed. Existing Blob
  media is not converted to Catalog mode.
- `pool create` provisions Catalog-mode Pool metadata only; it does not create
  an initialized Catalog or Volume. Creation requires a fresh scan-bound token.

Validation:

```sh
zig build test-data-node
zig build test-compatibility
zig build test-module-roots
zig build build-spdk-tests
```

The last gate compiles the existing SPDK integration libraries without starting
SPDK or touching disks. Real SPDK execution and the required Linux loop gate are
separate explicit test profiles; see [block safety](../../docs/block-safety.md).
