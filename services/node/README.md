# Zettide Node

`services/node/` owns Zettide's data-node product composition and platform or
protocol adapters. It consumes the public `zettide_storage` module from
`libs/storage-engine/`; it must not use cross-directory relative imports into
the engine.

Current compatibility surfaces remain unchanged:

- `zettide` CLI and its existing commands;
- `zettide endpoint serve` compatibility entry;
- `libzettide-nfs-backend.a`, `zettide/nfs_backend.h`, and `zettide_nfs_*` C ABI;
- endpoint control protocol and persisted desired-state format;
- SPDK export identities and lifecycle behavior.

`node_root.zig` is the named `zettide_node` module root. Tests, benchmarks,
SPDK consumers, and the NFS backend use explicit `zettide_node`/
`zettide_storage` imports. The legacy `zettide` facade is restricted to the
existing CLI sources.

Run `zig build test-node` for endpoint/SPDK adapter units,
`zig build test-compatibility` for CLI/frontend compatibility units, and
`zig build test-module-roots` for dependency-boundary checks.

`node_main.zig` and `node_data_service.zig` contain the DataService prototype;
installing the final `zettide-node` daemon remains a later composition step.
The repository root build owns product wiring during this migration.
