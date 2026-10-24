# Zettide Developer Guide

## Repository Scope

Zettide is single-node VM block storage with an in-house engine and local
multi-disk protection; see ADR 0005. Core components live in
`libs/storage-engine/` and `services/data-node/`. Tests live under `tests/`.
External source dependencies are pinned as submodules under `vendor/`.
Do not reintroduce a filesystem service, FUSE/NFS/CSI, a cluster controller,
cross-node replication, or TxFS. Preserve retired on-disk feature identities
for safe decoding and rejection, not as new product capabilities.

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
