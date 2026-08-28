# Zettide Developer Guide

## Repository Scope

This repository contains the complete Zettide storage project. Storage-owned
components live in `services/zettide/`, `services/control/`, `services/csi/`,
`services/nfs-fsal/`, `libs/cawfs/`, and `libs/data-service-contracts/`. Tests live under
`tests/`. External source dependencies are pinned as submodules under `vendor/`.

`qtr` and `etz` are separate projects and are not part of this repository's
build or test lifecycle.

## Zig Development Builds

During active development, keep the persistent incremental build running:

```bash
mise run dev
```

Incremental compilation is experimental and must not be used as the final
correctness gate. Before committing, run the regular non-incremental gates:

```bash
mise run test
mise run check
```

Do not add `-fincremental` or `--watch` to CI or release builds.
