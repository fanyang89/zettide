# 源码映射

本页把“当前/部分/目标”映射到源码入口。第三方 API、enum 或 test harness 不单独证明产品能力。

## 工作区入口

| 主题 | 文件 |
| --- | --- |
| 整体组件与 storage direction | [`../../../README.md`](../../../README.md) |
| Zettide 当前能力与 gate | [`../../../README.md`](../../../README.md) |
| qtr external storage/VM | [`../../../qtr/README.md`](../../../qtr/README.md), [`../../../qtr/docs/external-storage.md`](../../../qtr/docs/external-storage.md), [`../../../qtr/docs/vm-configuration.md`](../../../qtr/docs/vm-configuration.md) |
| 控制面范围 | [`../../../services/control/README.md`](../../../services/control/README.md) |
| Raft API、安全与恢复 | [`../../../vendor/raftz/README.md`](../../../vendor/raftz/README.md), [`../../../vendor/raftz/src/root.zig`](../../../vendor/raftz/src/root.zig) |
| grpc-lite API 与限制 | [`../../../vendor/grpc-lite/README.md`](../../../vendor/grpc-lite/README.md), [`../../../vendor/grpc-lite/src/root.zig`](../../../vendor/grpc-lite/src/root.zig) |
| 虚拟化/CSI 目标契约 | [`13-virtualization-and-csi.md`](13-virtualization-and-csi.md) |
| CAWFS 契约 | [`12-cawfs-shared-qcow2.md`](12-cawfs-shared-qcow2.md), [`../../../libs/cawfs/README.md`](../../../libs/cawfs/README.md) |

## Pool、BlobFilesystem 与 Catalog

| 主题 | 文件 |
| --- | --- |
| v3 format | [`../../../docs/v3-format.md`](../../../docs/v3-format.md) |
| Member format/topology/layout | [`../../../services/zettide/v3/member_format.zig`](../../../services/zettide/v3/member_format.zig), [`../../../services/zettide/v3/pool_topology.zig`](../../../services/zettide/v3/pool_topology.zig), [`../../../services/zettide/v3/pool_layout.zig`](../../../services/zettide/v3/pool_layout.zig) |
| Member bootstrap/storage | [`../../../services/zettide/v3/member_bootstrap.zig`](../../../services/zettide/v3/member_bootstrap.zig), [`../../../services/zettide/v3/member.zig`](../../../services/zettide/v3/member.zig), [`../../../services/zettide/v3/storage.zig`](../../../services/zettide/v3/storage.zig) |
| Provision/authority/member set | [`../../../services/zettide/v3/pool_provision.zig`](../../../services/zettide/v3/pool_provision.zig), [`../../../services/zettide/v3/pool_authority.zig`](../../../services/zettide/v3/pool_authority.zig), [`../../../services/zettide/v3/pool_member_set.zig`](../../../services/zettide/v3/pool_member_set.zig) |
| Membership/control history | [`../../../services/zettide/v3/membership.zig`](../../../services/zettide/v3/membership.zig), [`../../../services/zettide/v3/pool_replicated_journal.zig`](../../../services/zettide/v3/pool_replicated_journal.zig), [`../../../services/zettide/v3/control_record.zig`](../../../services/zettide/v3/control_record.zig) |
| Linux device safety/planning | [`../../../services/zettide/v3/linux_block_device.zig`](../../../services/zettide/v3/linux_block_device.zig), [`../../../services/zettide/v3/linux_pool_plan.zig`](../../../services/zettide/v3/linux_pool_plan.zig) |
| Pool data device/storage | [`../../../services/zettide/v3/pool_data_device.zig`](../../../services/zettide/v3/pool_data_device.zig), [`../../../services/zettide/v3/pool_data_storage.zig`](../../../services/zettide/v3/pool_data_storage.zig) |
| Scheduled data/blob layout | [`../../../services/zettide/v3/pool_scheduled_data_device.zig`](../../../services/zettide/v3/pool_scheduled_data_device.zig), [`../../../services/zettide/v3/pool_blob_schedule.zig`](../../../services/zettide/v3/pool_blob_schedule.zig) |
| BlobFilesystem | [`../../../services/zettide/blob_filesystem.zig`](../../../services/zettide/blob_filesystem.zig), [`../../../services/zettide/filesystem_target.zig`](../../../services/zettide/filesystem_target.zig) |
| FUSE frontend 与 Blob adapter | [`../../../services/zettide/linux_fuse.zig`](../../../services/zettide/linux_fuse.zig), [`../../../services/zettide/blob_filesystem_adapter.zig`](../../../services/zettide/blob_filesystem_adapter.zig) |
| Multi-Volume format | [`../../../docs/v3-multivolume-format.md`](../../../docs/v3-multivolume-format.md) |
| Catalog Volume/mutation | [`../../../services/zettide/v3/pool_catalog_volume.zig`](../../../services/zettide/v3/pool_catalog_volume.zig), [`../../../services/zettide/v3/pool_catalog_mutation.zig`](../../../services/zettide/v3/pool_catalog_mutation.zig) |
| Catalog graph/store/page | [`../../../services/zettide/v3/pool_catalog_graph.zig`](../../../services/zettide/v3/pool_catalog_graph.zig), [`../../../services/zettide/v3/pool_catalog_store.zig`](../../../services/zettide/v3/pool_catalog_store.zig), [`../../../services/zettide/v3/pool_catalog_page.zig`](../../../services/zettide/v3/pool_catalog_page.zig) |
| Local ReplicaEndpoint | [`../../../services/zettide/v3/replica_endpoint.zig`](../../../services/zettide/v3/replica_endpoint.zig) |
| v3 module entry | [`../../../services/zettide/v3/root.zig`](../../../services/zettide/v3/root.zig) |

`ReplicaEndpoint` 是本地 vtable；v3 control journal 是 Pool control history，二者都不是 Tier 3 Replica protocol。

## Endpoint Daemon 与标准 NVMf

| 主题 | 文件 |
| --- | --- |
| Product endpoint daemon | [`../../../services/zettide/endpoint_daemon.zig`](../../../services/zettide/endpoint_daemon.zig) |
| Versioned owner-only Unix API | [`../../../services/zettide/endpoint_control.zig`](../../../services/zettide/endpoint_control.zig) |
| Persistent desired state/registry | [`../../../services/zettide/endpoint_registry.zig`](../../../services/zettide/endpoint_registry.zig) |
| Catalog endpoint backend | [`../../../services/zettide/spdk/catalog_endpoint_backend.zig`](../../../services/zettide/spdk/catalog_endpoint_backend.zig) |
| Catalog Volume to NVMf export | [`../../../services/zettide/spdk/catalog_nvmf_export.zig`](../../../services/zettide/spdk/catalog_nvmf_export.zig) |
| Standard NVMf TCP/RDMA export wrapper | [`../../../services/zettide/spdk/nvmf_tcp_export.zig`](../../../services/zettide/spdk/nvmf_tcp_export.zig), [`../../../services/zettide/spdk/nvmf_tcp_export.c`](../../../services/zettide/spdk/nvmf_tcp_export.c), [`../../../services/zettide/spdk/nvmf_tcp_export.h`](../../../services/zettide/spdk/nvmf_tcp_export.h) |
| Catalog async backend/provider bdev | [`../../../services/zettide/spdk/catalog_volume_backend.zig`](../../../services/zettide/spdk/catalog_volume_backend.zig), [`../../../services/zettide/spdk/provider_bdev.zig`](../../../services/zettide/spdk/provider_bdev.zig), [`../../../services/zettide/spdk/bdev_provider.c`](../../../services/zettide/spdk/bdev_provider.c) |
| Managed SPDK runtime | [`../../../services/zettide/spdk/runtime.zig`](../../../services/zettide/spdk/runtime.zig), [`../../../services/zettide/spdk/runtime.c`](../../../services/zettide/spdk/runtime.c) |
| SPDK bdev storage/dispatcher | [`../../../services/zettide/spdk/storage.zig`](../../../services/zettide/spdk/storage.zig), [`../../../services/zettide/spdk/bdev_dispatcher.c`](../../../services/zettide/spdk/bdev_dispatcher.c) |
| SPDK endpoint/provider C ABI | [`../../../services/zettide/spdk/bdev_endpoint.c`](../../../services/zettide/spdk/bdev_endpoint.c), [`../../../services/zettide/spdk/bdev_endpoint.h`](../../../services/zettide/spdk/bdev_endpoint.h), [`../../../services/zettide/spdk/bdev_provider.h`](../../../services/zettide/spdk/bdev_provider.h) |
| NVMe-oF initiator | [`../../../services/zettide/spdk/nvme_controller.zig`](../../../services/zettide/spdk/nvme_controller.zig), [`../../../services/zettide/spdk/nvme_controller.c`](../../../services/zettide/spdk/nvme_controller.c) |
| NVMf export tests | [`../../../tests/spdk_nvmf_export.zig`](../../../tests/spdk_nvmf_export.zig), [`../../../tests/spdk-nvmf-fio.sh`](../../../tests/spdk-nvmf-fio.sh), [`../../../tests/automation/nvmf-catalog-fio.yml`](../../../tests/automation/nvmf-catalog-fio.yml) |
| vhost-user-blk | [`../../../services/zettide/spdk/catalog_vhost_export.zig`](../../../services/zettide/spdk/catalog_vhost_export.zig), [`../../../services/zettide/spdk/vhost_block_export.zig`](../../../services/zettide/spdk/vhost_block_export.zig) |
| Physical/scheduled Pool gates | [`../../../tests/physical-pool-fio.sh`](../../../tests/physical-pool-fio.sh), [`../../../tests/scheduled-pool-nvmf-fio.sh`](../../../tests/scheduled-pool-nvmf-fio.sh), [`../../../tests/scheduled-blob-pool-fuse-fio.sh`](../../../tests/scheduled-blob-pool-fuse-fio.sh) |
| Hardware/RDMA NVMf gates | [`../../../tests/automation/nvmf-catalog-optane-fio.yml`](../../../tests/automation/nvmf-catalog-optane-fio.yml), [`../../../tests/automation/nvmf-catalog-rxe-fio.yml`](../../../tests/automation/nvmf-catalog-rxe-fio.yml), [`../../../tests/automation/nvmf-scheduled-pool-rxe-fio.yml`](../../../tests/automation/nvmf-scheduled-pool-rxe-fio.yml) |

这些文件证明标准 host-facing Catalog NVMf target subsystem/namespace/listener 与 endpoint daemon 已有部分实现。它们不证明 qtr managed E2E、consumer access-generation fencing、真实四前端多盘 gate 或 Tier 3 internal Replica protocol。

## NFS Backend 与 FSAL

| 主题 | 文件 |
| --- | --- |
| NFS filesystem abstraction | [`../../../services/zettide/nfs_filesystem.zig`](../../../services/zettide/nfs_filesystem.zig) |
| Blob adapter | [`../../../services/zettide/nfs_blob_adapter.zig`](../../../services/zettide/nfs_blob_adapter.zig) |
| Stable NFS handle | [`../../../services/zettide/nfs_handle.zig`](../../../services/zettide/nfs_handle.zig) |
| Zig C ABI backend | [`../../../services/zettide/nfs_backend.zig`](../../../services/zettide/nfs_backend.zig), [`../../../services/zettide/nfs_backend.h`](../../../services/zettide/nfs_backend.h) |
| NFS-Ganesha module | [`../../../services/nfs-fsal/README.md`](../../../services/nfs-fsal/README.md), [`../../../services/nfs-fsal/main.c`](../../../services/nfs-fsal/main.c), [`../../../services/nfs-fsal/export.c`](../../../services/nfs-fsal/export.c), [`../../../services/nfs-fsal/handle.c`](../../../services/nfs-fsal/handle.c) |
| NFSv3 RPC gate | [`../../../tests/nfs-ganesha.sh`](../../../tests/nfs-ganesha.sh), [`../../../tests/automation/blob-pool-nfs-fio.yml`](../../../tests/automation/blob-pool-nfs-fio.yml) |

当前 backend/FSAL 只打开 standalone regular-file target 或一个 Pool Member，
不组装多成员 Pool，因此 NFS 状态是“部分”。

## qtr

| 主题 | 文件 |
| --- | --- |
| 手动 external iSCSI backend、scan、login/logout、device discovery | [`../../../qtr/src/storage.rs`](../../../qtr/src/storage.rs) |
| Storage CLI schema | [`../../../qtr/src/config.rs`](../../../qtr/src/config.rs) |
| VM file/block path 与 libvirt lifecycle | [`../../../qtr/src/vm.rs`](../../../qtr/src/vm.rs) |
| VM desired/observed reconciliation | [`../../../qtr/src/vm_model.rs`](../../../qtr/src/vm_model.rs), [`../../../qtr/src/vm_reconcile.rs`](../../../qtr/src/vm_reconcile.rs) |

当前没有 qtr Zettide provider、managed NVMf controller、Publication API client、protocol fallback、persistent attachment intent 或 end-to-end reconciliation。

## zettide-control / raftz / grpc-lite

| 主题 | 文件 |
| --- | --- |
| Control protobuf | [`../../../services/control/proto/zettide/control/v1/control.proto`](../../../services/control/proto/zettide/control/v1/control.proto) |
| State machine/snapshot/idempotency | [`../../../services/control/src/state_machine.zig`](../../../services/control/src/state_machine.zig) |
| Heartbeat | [`../../../services/control/src/heartbeat.zig`](../../../services/control/src/heartbeat.zig) |
| RPC/ReadIndex | [`../../../services/control/src/service.zig`](../../../services/control/src/service.zig) |
| Runtime/WAL/transport | [`../../../services/control/src/runtime.zig`](../../../services/control/src/runtime.zig) |
| Config/data_dir 与进程入口 | [`../../../services/control/src/config.zig`](../../../services/control/src/config.zig), [`../../../services/control/src/main.zig`](../../../services/control/src/main.zig) |
| Control module/wire/build | [`../../../services/control/src/root.zig`](../../../services/control/src/root.zig), [`../../../services/control/src/protobuf_wire.zig`](../../../services/control/src/protobuf_wire.zig), [`../../../services/control/build.zig`](../../../services/control/build.zig) |
| Control restart/failover tests | [`../../../services/control/src/runtime_integration_test.zig`](../../../services/control/src/runtime_integration_test.zig), [`../../../services/control/src/integration_test.zig`](../../../services/control/src/integration_test.zig) |
| Raftor/WAL/grpc transport | [`../../../vendor/raftz/src/raftor.zig`](../../../vendor/raftz/src/raftor.zig), [`../../../vendor/raftz/src/wal.zig`](../../../vendor/raftz/src/wal.zig), [`../../../vendor/raftz/src/rpc/grpc_lite_transport.zig`](../../../vendor/raftz/src/rpc/grpc_lite_transport.zig) |
| Raft core/RawNode/Ready | [`../../../vendor/raftz/src/raft.zig`](../../../vendor/raftz/src/raft.zig), [`../../../vendor/raftz/src/raw_node.zig`](../../../vendor/raftz/src/raw_node.zig), [`../../../vendor/raftz/src/ready_processor.zig`](../../../vendor/raftz/src/ready_processor.zig) |
| Raft StateMachine/membership | [`../../../vendor/raftz/src/state_machine.zig`](../../../vendor/raftz/src/state_machine.zig), [`../../../vendor/raftz/src/cluster_membership.zig`](../../../vendor/raftz/src/cluster_membership.zig) |
| Raft queue/snapshot config | [`../../../vendor/raftz/src/raftor_config.zig`](../../../vendor/raftz/src/raftor_config.zig), [`../../../vendor/raftz/src/proposal_queue.zig`](../../../vendor/raftz/src/proposal_queue.zig), [`../../../vendor/raftz/src/wal/snapshot_store.zig`](../../../vendor/raftz/src/wal/snapshot_store.zig) |
| Raft request/proposal tracking | [`../../../vendor/raftz/src/request_context.zig`](../../../vendor/raftz/src/request_context.zig), [`../../../vendor/raftz/src/proposal_tracker.zig`](../../../vendor/raftz/src/proposal_tracker.zig) |
| Raft storage/transport abstraction | [`../../../vendor/raftz/src/storage.zig`](../../../vendor/raftz/src/storage.zig), [`../../../vendor/raftz/src/transport.zig`](../../../vendor/raftz/src/transport.zig) |
| Segmented WAL internals | [`../../../vendor/raftz/src/wal/segment.zig`](../../../vendor/raftz/src/wal/segment.zig), [`../../../vendor/raftz/src/wal/segment_manager.zig`](../../../vendor/raftz/src/wal/segment_manager.zig), [`../../../vendor/raftz/src/wal/metadata_store.zig`](../../../vendor/raftz/src/wal/metadata_store.zig) |
| Raft multi-node/grpc tests | [`../../../vendor/raftz/tests/multi_node_test.zig`](../../../vendor/raftz/tests/multi_node_test.zig), [`../../../vendor/raftz/tests/grpc_raftor_test.zig`](../../../vendor/raftz/tests/grpc_raftor_test.zig) |
| grpc-lite API/TLS boundaries | [`../../../vendor/grpc-lite/src/channel.zig`](../../../vendor/grpc-lite/src/channel.zig), [`../../../vendor/grpc-lite/src/server.zig`](../../../vendor/grpc-lite/src/server.zig) |
| grpc-lite streaming/metadata/deadline | [`../../../vendor/grpc-lite/src/stream.zig`](../../../vendor/grpc-lite/src/stream.zig), [`../../../vendor/grpc-lite/src/metadata.zig`](../../../vendor/grpc-lite/src/metadata.zig), [`../../../vendor/grpc-lite/src/deadline.zig`](../../../vendor/grpc-lite/src/deadline.zig) |
| grpc-lite interoperability | [`../../../vendor/grpc-lite/tests/official/README.md`](../../../vendor/grpc-lite/tests/official/README.md) |

## Vendored SPDK 参考边界

| 主题 | 文件 |
| --- | --- |
| NVMf API/target entry | [`../../../vendor/spdk/include/spdk/nvmf.h`](../../../vendor/spdk/include/spdk/nvmf.h), [`../../../vendor/spdk/app/nvmf_tgt/nvmf_main.c`](../../../vendor/spdk/app/nvmf_tgt/nvmf_main.c) |
| NVMf subsystem/transports | [`../../../vendor/spdk/lib/nvmf/subsystem.c`](../../../vendor/spdk/lib/nvmf/subsystem.c), [`../../../vendor/spdk/lib/nvmf/tcp.c`](../../../vendor/spdk/lib/nvmf/tcp.c), [`../../../vendor/spdk/lib/nvmf/rdma.c`](../../../vendor/spdk/lib/nvmf/rdma.c) |
| SPDK bdev API | [`../../../vendor/spdk/include/spdk/bdev.h`](../../../vendor/spdk/include/spdk/bdev.h) |
| iSCSI target reference | [`../../../vendor/spdk/app/iscsi_tgt/iscsi_tgt.c`](../../../vendor/spdk/app/iscsi_tgt/iscsi_tgt.c) |

Vendored API/target 只证明依赖中存在相应原语，不证明 Zettide 已封装产品 lifecycle。当前 Zettide 已封装标准 Catalog NVMf export；iSCSI target 和 Tier 3 vendor-specific Replica target 仍未实现。

当前 control Volume 是 metadata intent；无 placement、Replica/Allocation mutation、lease、publication authority 或 reconciliation。

## CAWFS

| 主题 | 文件 |
| --- | --- |
| Transaction/Store | [`../../../libs/cawfs/src/transaction.zig`](../../../libs/cawfs/src/transaction.zig), [`../../../libs/cawfs/src/store.zig`](../../../libs/cawfs/src/store.zig) |
| SCSI CAW/whole-LUN transport | [`../../../libs/cawfs/src/scsi.zig`](../../../libs/cawfs/src/scsi.zig), [`../../../libs/cawfs/src/linux_sg_io.zig`](../../../libs/cawfs/src/linux_sg_io.zig) |
| Mutable data/allocator | [`../../../libs/cawfs/src/data_block.zig`](../../../libs/cawfs/src/data_block.zig), [`../../../libs/cawfs/src/extent_allocator.zig`](../../../libs/cawfs/src/extent_allocator.zig) |
| Filesystem/format/maintenance | [`../../../libs/cawfs/src/filesystem.zig`](../../../libs/cawfs/src/filesystem.zig), [`../../../libs/cawfs/src/filesystem_format.zig`](../../../libs/cawfs/src/filesystem_format.zig), [`../../../libs/cawfs/src/maintenance.zig`](../../../libs/cawfs/src/maintenance.zig) |
| SCSI immutable Store | [`../../../libs/cawfs/src/scsi_store.zig`](../../../libs/cawfs/src/scsi_store.zig), [`../../../libs/cawfs/src/immutable_extent.zig`](../../../libs/cawfs/src/immutable_extent.zig) |

## 尚无实现

- Zettide iSCSI target/publication lifecycle。
- qtr managed NVMf-first backend、PVE plugin、CSI driver。
- NFS multi-member Pool export 与四前端真实多物理盘总 gate。
- Tier 2 online Pool/protection migration product lifecycle。
- Tier 3 vendor-specific Replica NVMf、commit evidence、epoch fencing、failover/repair。
- 生产级双向认证、细粒度授权与 credential rotation。
