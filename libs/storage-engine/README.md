# Zettide Storage Engine

`zettide_storage` is Zettide's reusable, in-process storage engine. It owns the
backend-neutral storage contract, persistent formats, Pool/Member/Catalog,
Blob/BlobFilesystem, and backend-neutral filesystem ports.

It does not depend on endpoint lifecycle, SPDK, FUSE, CLI, RPC, DataService, or
the controller. Platform and process adapters live under `services/data-node/`.

Run the library-local gates with:

```sh
zig build test
zig build ci
```

The repository root integrates this package through
`libs/storage-engine/build.zig:addComponent` and exposes the same portable suite
as `zig build test-storage-engine`.

Pool/Catalog/Blob remain one package after the post-extraction review; see
[ADR 0002](../../docs/decisions/0002-keep-storage-engine-cohesive.md). Internal
module boundaries may continue to narrow, but a new package requires independent
consumer, DAG, validation, and release evidence.

Disk formats and public compatibility surfaces are unchanged by the repository
move.
