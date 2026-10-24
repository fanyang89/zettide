# Zettide Developer Guide

## Repository Scope

Zettide is single-node VM block storage with an in-house engine and local
multi-disk protection; see ADR 0005. Core components live in
`libs/storage-engine/` and `services/data-node/`. Tests live under `tests/`.
External source dependencies are pinned as submodules under `vendor/`.
Filesystem code and `services/nfs-fsal/` are transitional removal candidates,
not active product directions. Do not reintroduce a cluster controller,
cross-node replication, TxFS, or CSI.

`qtr` and `etz` are separate projects and are not part of this repository's
build or test lifecycle.

## Zig Development Builds

During active development, keep the persistent incremental build running:

```bash
mise run dev
```

For focused storage-engine work, run `cd libs/storage-engine && zig build ci`;
from the repository root use `zig build test-storage-engine`, `test-data-node`,
`test-compatibility`, and `test-module-roots` for explicit boundaries.

Incremental compilation is experimental and must not be used as the final
correctness gate. Before committing, run the regular non-incremental gates:

```bash
mise run test
mise run check
```

Do not add `-fincremental` or `--watch` to CI or release builds.
