# Component boundaries

The current product boundary is [ADR 0005](../../decisions/0005-single-node-vm-block-storage.md).
The one-package engine rule from ADR 0002 remains in effect.

- `libs/storage-engine/` owns backend-neutral Pool/Member/Catalog/Volume,
  persistent formats, local multi-disk protection, journal, and recovery.
- The engine must not import data-node sources, SPDK, CLI parsing, endpoint
  lifecycle, network RPC, or process management.
- `services/data-node/` consumes the public `zettide_storage` module. It owns
  file/block device adapters, the local operator CLI, SPDK, and endpoint state.
- Tests may exercise engine and platform modules together, but test fixtures
  must not create production dependency reversals.
- A writable Pool has one process owner. Protocol wrappers must hold the
  appropriate Catalog data lease until I/O and export teardown have completed.
- Multi-Volume publication requires explicit shared Pool ownership and lease
  coordination. The registry's current one-endpoint-per-Pool guard stays in place.
- Retired Blob feature bits, geometry, and local layout codecs are compatibility
  contracts, not filesystem service boundaries. Never reuse their persisted
  identities for Catalog data.

`test-storage-engine`, `test-data-node`, `test-module-roots`, and
`test-compatibility` validate the current module boundaries. `test-cross`
compiles portable block contracts; `build-spdk-tests` compiles integration
libraries without requiring an SPDK runtime. These checks do not prove physical
multi-disk durability or a complete managed VM lifecycle.
