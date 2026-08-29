# Zettide Data Node

`services/data-node/` owns Zettide's data-node product composition and platform or
protocol adapters. It consumes the public `zettide_storage` module from
`libs/storage-engine/`; it must not use cross-directory relative imports into
the engine.

Current data-node/platform capabilities include the endpoint registry and daemon,
Catalog exports over NVMf TCP/RDMA, iSCSI, and vhost-user-blk, plus the Linux
FUSE/NFS/dufs adapters. These are component and compatibility lifecycles; they
do not yet form the final `zettide-data-node` managed Publication service.

Current compatibility surfaces remain unchanged:

- `zettide` CLI and its existing commands;
- `zettide endpoint serve` compatibility entry;
- `libzettide-nfs-backend.a`, `zettide/nfs_backend.h`, and `zettide_nfs_*` C ABI;
- endpoint control protocol and persisted desired-state format;
- SPDK export identities and lifecycle behavior.

`data_node_root.zig` is the named `zettide_data_node` module root. Tests, benchmarks,
SPDK consumers, and the NFS backend use explicit `zettide_data_node`/
`zettide_storage` imports. The legacy `zettide` facade is restricted to the
existing CLI sources.

The iSCSI path includes a shared SPDK service, per-Catalog target/LUN export,
endpoint locator wiring, and the remote `tests/automation/iscsi-catalog-fio.yml`
profile. It still lacks consumer-bound access generation and managed attachment
reconciliation.

Run `zig build test-data-node` for endpoint/SPDK adapter units,
`zig build test-compatibility` for CLI/frontend compatibility units, and
`zig build test-module-roots` for dependency-boundary checks.

`data_node_main.zig` and `data_node_service.zig` expose the DataService control
endpoint. The repository root build installs `zettide-data-node`; the daemon starts that
endpoint and registers its stable Node identity and advertised data endpoint
with the controller.

For development provisioning, configure all of `--state-dir`, `--member-file`,
`--member-id`, `--pool-id`, `--member-metadata-capacity`, `--member-capacity`, and
`--extent-size`. The daemon registers the file Member, advances a durable process
incarnation, and reports sequenced capacity heartbeats at the interval returned
by the controller. The target Pool must already exist.

Replica operations are persisted in `replicas.state`, fence evidence in
`fences.state`, accepted authority epochs/recovery evidence in `authority.state`,
the physical file-object generation in `member-generation.state`, and configured
participants in `write-catalog.state` plus per-generation `write-*.state`
snapshots. An exclusive `daemon.lock` prevents two processes from sharing
that state directory. The daemon binds the ledger to an opened backing-file
inode, validates allocations against its fixed geometry, rejects overlap,
retains deleted extents in quarantine, and reports
free/allocated/reserved/retired extent counts. Lease deadlines remain
process-local and fail closed after restart; the maximum accepted write epoch is
durable. An uncertain parent-directory sync poisons the affected ledger until
restart/reopen rather than allowing a later operation to overwrite it. Omitting
all seven options keeps Replica, fence, recovery, and Member
heartbeat operations disabled while holder/lease diagnostics remain available.

This file-member backend now includes a node-local, daemon-owned write
participant manager. It persists an immutable Replica/canonical-Member binding
and catalog, retains retired generations for recovery evidence, validates the
complete active Replica and physical-object generation before each 4 KiB-aligned
positional write, synchronizes the member file, and eagerly drains
a durable COMMIT on startup. Normal admission checks the exact live ready
authority and durable fence; certified replay bypasses lease expiry but is
rejected after a different/higher fence. Replica mutation and fencing take the
same participant/control barrier through the durable fence append; undecided or
poisoned state blocks deletion/fencing, and deletion durably retires the catalog
entry before allowing generation rollover.

The manager is intentionally not exposed on the current management listener and
the controller does not yet provision canonical write sets. Therefore a
three-node Volume intent can reach `ACTIVE`, but user writes are still not
replicated or published to hosts. Authenticated cross-node Replica transport,
primary coordination, 2/3 success, recovery/repair, and authority-gated
Publication remain subsequent steps. See `tests/e2e/README.md` for the Docker
Compose profile.
