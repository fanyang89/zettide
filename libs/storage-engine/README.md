# Zettide Storage Engine

`zettide_storage` is Zettide's reusable, in-process storage engine. It owns the
backend-neutral block storage contract, persistent formats, Pool/Member/Catalog,
Volume extent maps, local multi-disk protection, and recovery.

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

Pool/Catalog remain one package after the post-extraction review; see
[ADR 0002](../../docs/decisions/0002-keep-storage-engine-cohesive.md). Internal
module boundaries may continue to narrow, but a new package requires independent
consumer, DAG, validation, and release evidence.

The filesystem engine and its public exports have been removed under
[ADR 0005](../../docs/decisions/0005-single-node-vm-block-storage.md). Shared
on-disk feature bits, geometry checks, and layout codecs are retained for
compatibility and validation. The fixed and scheduled raw Blob data-plane
adapters are removed; they are not an alternative to Catalog Volume I/O.
Catalog replica reads, data leases, journal durability, and recovery remain.
Retired format recognition never authorizes reinterpreting Blob media as Volumes.

From the repository root, `zig build test-catalog-io` exercises the retained
Catalog data path and Linux request worker with regular-file Members. It runs
in the default test gate without starting SPDK; SPDK storage integration uses
the same test-only Catalog initialization fixture.
