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
`fences.state`, and accepted authority epochs/recovery evidence in
`authority.state`. An exclusive `daemon.lock` prevents two processes from sharing
that state directory. The daemon binds the ledger to an opened backing-file
inode, validates allocations against its fixed geometry, rejects overlap,
retains deleted extents in quarantine, and reports
free/allocated/reserved/retired extent counts. Lease deadlines remain
process-local and fail closed after restart; the maximum accepted write epoch is
durable. An uncertain parent-directory sync poisons the affected ledger until
restart/reopen rather than allowing a later operation to overwrite it. Omitting
all seven options keeps Replica, fence, recovery, and Member
heartbeat operations disabled while holder/lease diagnostics remain available.

This file-member backend establishes a durable control-plane boundary only. It
can drive a three-node Volume intent to `ACTIVE`, but does not replicate user
writes or publish that Volume to hosts. Cross-node Replica transport, durable
write certificates, repair, and authority-gated Publication remain subsequent
composition steps. See `tests/e2e/README.md` for the Docker Compose profile.
