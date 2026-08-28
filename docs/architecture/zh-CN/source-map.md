# 源码映射

本页把“当前/部分/目标”映射到源码入口。第三方 API、enum 或 test harness 不单独证明产品能力。

## 工作区入口

| 主题 | 文件 |
| --- | --- |
| 整体组件与 storage direction | [`../../../README.md`](../../../README.md) |
| Zettide 当前能力与 gate | [`../../../README.md`](../../../README.md) |
| qtr external storage/VM | [`../../../qtr/README.md`](../../../qtr/README.md), [`../../../qtr/docs/external-storage.md`](../../../qtr/docs/external-storage.md), [`../../../qtr/docs/vm-configuration.md`](../../../qtr/docs/vm-configuration.md) |
| 控制面范围 | [`../../../control/README.md`](../../../control/README.md) |
| Raft API、安全与恢复 | [`../../../raftz/README.md`](../../../raftz/README.md), [`../../../raftz/src/root.zig`](../../../raftz/src/root.zig) |
| grpc-lite API 与限制 | [`../../../grpc-lite/README.md`](../../../grpc-lite/README.md), [`../../../grpc-lite/src/root.zig`](../../../grpc-lite/src/root.zig) |
| 虚拟化/CSI 目标契约 | [`13-virtualization-and-csi.md`](13-virtualization-and-csi.md) |
| CAWFS 契约 | [`12-cawfs-shared-qcow2.md`](12-cawfs-shared-qcow2.md), [`../../../cawfs/README.md`](../../../cawfs/README.md) |

## Pool、BlobFilesystem 与 Catalog

| 主题 | 文件 |
| --- | --- |
| v3 format | [`../../../docs/v3-format.md`](../../../docs/v3-format.md) |
| Member format/topology/layout | [`../../../src/v3/member_format.zig`](../../../src/v3/member_format.zig), [`../../../src/v3/pool_topology.zig`](../../../src/v3/pool_topology.zig), [`../../../src/v3/pool_layout.zig`](../../../src/v3/pool_layout.zig) |
| Member bootstrap/storage | [`../../../src/v3/member_bootstrap.zig`](../../../src/v3/member_bootstrap.zig), [`../../../src/v3/member.zig`](../../../src/v3/member.zig), [`../../../src/v3/storage.zig`](../../../src/v3/storage.zig) |
| Provision/authority/member set | [`../../../src/v3/pool_provision.zig`](../../../src/v3/pool_provision.zig), [`../../../src/v3/pool_authority.zig`](../../../src/v3/pool_authority.zig), [`../../../src/v3/pool_member_set.zig`](../../../src/v3/pool_member_set.zig) |
| Membership/control history | [`../../../src/v3/membership.zig`](../../../src/v3/membership.zig), [`../../../src/v3/pool_replicated_journal.zig`](../../../src/v3/pool_replicated_journal.zig), [`../../../src/v3/control_record.zig`](../../../src/v3/control_record.zig) |
| Linux device safety/planning | [`../../../src/v3/linux_block_device.zig`](../../../src/v3/linux_block_device.zig), [`../../../src/v3/linux_pool_plan.zig`](../../../src/v3/linux_pool_plan.zig) |
| Pool data device/storage | [`../../../src/v3/pool_data_device.zig`](../../../src/v3/pool_data_device.zig), [`../../../src/v3/pool_data_storage.zig`](../../../src/v3/pool_data_storage.zig) |
| Scheduled data/blob layout | [`../../../src/v3/pool_scheduled_data_device.zig`](../../../src/v3/pool_scheduled_data_device.zig), [`../../../src/v3/pool_blob_schedule.zig`](../../../src/v3/pool_blob_schedule.zig) |
| BlobFilesystem | [`../../../src/blob_filesystem.zig`](../../../src/blob_filesystem.zig), [`../../../src/filesystem_target.zig`](../../../src/filesystem_target.zig) |
| FUSE frontend 与 Blob adapter | [`../../../src/linux_fuse.zig`](../../../src/linux_fuse.zig), [`../../../src/blob_filesystem_adapter.zig`](../../../src/blob_filesystem_adapter.zig) |
| Multi-Volume format | [`../../../docs/v3-multivolume-format.md`](../../../docs/v3-multivolume-format.md) |
| Catalog Volume/mutation | [`../../../src/v3/pool_catalog_volume.zig`](../../../src/v3/pool_catalog_volume.zig), [`../../../src/v3/pool_catalog_mutation.zig`](../../../src/v3/pool_catalog_mutation.zig) |
| Catalog graph/store/page | [`../../../src/v3/pool_catalog_graph.zig`](../../../src/v3/pool_catalog_graph.zig), [`../../../src/v3/pool_catalog_store.zig`](../../../src/v3/pool_catalog_store.zig), [`../../../src/v3/pool_catalog_page.zig`](../../../src/v3/pool_catalog_page.zig) |
| Local ReplicaEndpoint | [`../../../src/v3/replica_endpoint.zig`](../../../src/v3/replica_endpoint.zig) |
| v3 module entry | [`../../../src/v3/root.zig`](../../../src/v3/root.zig) |

`ReplicaEndpoint` 是本地 vtable；v3 control journal 是 Pool control history，二者都不是 Tier 3 Replica protocol。

## Endpoint Daemon 与标准 NVMf

| 主题 | 文件 |
| --- | --- |
| Product endpoint daemon | [`../../../src/endpoint_daemon.zig`](../../../src/endpoint_daemon.zig) |
| Versioned owner-only Unix API | [`../../../src/endpoint_control.zig`](../../../src/endpoint_control.zig) |
| Persistent desired state/registry | [`../../../src/endpoint_registry.zig`](../../../src/endpoint_registry.zig) |
| Catalog endpoint backend | [`../../../src/spdk/catalog_endpoint_backend.zig`](../../../src/spdk/catalog_endpoint_backend.zig) |
| Catalog Volume to NVMf export | [`../../../src/spdk/catalog_nvmf_export.zig`](../../../src/spdk/catalog_nvmf_export.zig) |
| Standard NVMf TCP/RDMA export wrapper | [`../../../src/spdk/nvmf_tcp_export.zig`](../../../src/spdk/nvmf_tcp_export.zig), [`../../../src/spdk/nvmf_tcp_export.c`](../../../src/spdk/nvmf_tcp_export.c), [`../../../src/spdk/nvmf_tcp_export.h`](../../../src/spdk/nvmf_tcp_export.h) |
| Catalog async backend/provider bdev | [`../../../src/spdk/catalog_volume_backend.zig`](../../../src/spdk/catalog_volume_backend.zig), [`../../../src/spdk/provider_bdev.zig`](../../../src/spdk/provider_bdev.zig), [`../../../src/spdk/bdev_provider.c`](../../../src/spdk/bdev_provider.c) |
| Managed SPDK runtime | [`../../../src/spdk/runtime.zig`](../../../src/spdk/runtime.zig), [`../../../src/spdk/runtime.c`](../../../src/spdk/runtime.c) |
| SPDK bdev storage/dispatcher | [`../../../src/spdk/storage.zig`](../../../src/spdk/storage.zig), [`../../../src/spdk/bdev_dispatcher.c`](../../../src/spdk/bdev_dispatcher.c) |
| SPDK endpoint/provider C ABI | [`../../../src/spdk/bdev_endpoint.c`](../../../src/spdk/bdev_endpoint.c), [`../../../src/spdk/bdev_endpoint.h`](../../../src/spdk/bdev_endpoint.h), [`../../../src/spdk/bdev_provider.h`](../../../src/spdk/bdev_provider.h) |
| NVMe-oF initiator | [`../../../src/spdk/nvme_controller.zig`](../../../src/spdk/nvme_controller.zig), [`../../../src/spdk/nvme_controller.c`](../../../src/spdk/nvme_controller.c) |
| NVMf export tests | [`../../../test/spdk_nvmf_export.zig`](../../../test/spdk_nvmf_export.zig), [`../../../test/spdk-nvmf-fio.sh`](../../../test/spdk-nvmf-fio.sh), [`../../../test/ansible/nvmf-catalog-fio.yml`](../../../test/ansible/nvmf-catalog-fio.yml) |
| vhost-user-blk | [`../../../src/spdk/catalog_vhost_export.zig`](../../../src/spdk/catalog_vhost_export.zig), [`../../../src/spdk/vhost_block_export.zig`](../../../src/spdk/vhost_block_export.zig) |
| Physical/scheduled Pool gates | [`../../../test/physical-pool-fio.sh`](../../../test/physical-pool-fio.sh), [`../../../test/scheduled-pool-nvmf-fio.sh`](../../../test/scheduled-pool-nvmf-fio.sh), [`../../../test/scheduled-blob-pool-fuse-fio.sh`](../../../test/scheduled-blob-pool-fuse-fio.sh) |
| Hardware/RDMA NVMf gates | [`../../../test/ansible/nvmf-catalog-optane-fio.yml`](../../../test/ansible/nvmf-catalog-optane-fio.yml), [`../../../test/ansible/nvmf-catalog-rxe-fio.yml`](../../../test/ansible/nvmf-catalog-rxe-fio.yml), [`../../../test/ansible/nvmf-scheduled-pool-rxe-fio.yml`](../../../test/ansible/nvmf-scheduled-pool-rxe-fio.yml) |

这些文件证明标准 host-facing Catalog NVMf target subsystem/namespace/listener 与 endpoint daemon 已有部分实现。它们不证明 qtr managed E2E、consumer access-generation fencing、真实四前端多盘 gate 或 Tier 3 internal Replica protocol。

## NFS Backend 与 FSAL

| 主题 | 文件 |
| --- | --- |
| NFS filesystem abstraction | [`../../../src/nfs_filesystem.zig`](../../../src/nfs_filesystem.zig) |
| Blob adapter | [`../../../src/nfs_blob_adapter.zig`](../../../src/nfs_blob_adapter.zig) |
| Stable NFS handle | [`../../../src/nfs_handle.zig`](../../../src/nfs_handle.zig) |
| Zig C ABI backend | [`../../../src/nfs_backend.zig`](../../../src/nfs_backend.zig), [`../../../src/nfs_backend.h`](../../../src/nfs_backend.h) |
| NFS-Ganesha module | [`../../../fsal/zettide/README.md`](../../../fsal/zettide/README.md), [`../../../fsal/zettide/main.c`](../../../fsal/zettide/main.c), [`../../../fsal/zettide/export.c`](../../../fsal/zettide/export.c), [`../../../fsal/zettide/handle.c`](../../../fsal/zettide/handle.c) |
| NFSv3 RPC gate | [`../../../test/nfs-ganesha.sh`](../../../test/nfs-ganesha.sh), [`../../../test/ansible/blob-pool-nfs-fio.yml`](../../../test/ansible/blob-pool-nfs-fio.yml) |

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
| Control protobuf | [`../../../control/proto/zettide/control/v1/control.proto`](../../../control/proto/zettide/control/v1/control.proto) |
| State machine/snapshot/idempotency | [`../../../control/src/state_machine.zig`](../../../control/src/state_machine.zig) |
| Heartbeat | [`../../../control/src/heartbeat.zig`](../../../control/src/heartbeat.zig) |
| RPC/ReadIndex | [`../../../control/src/service.zig`](../../../control/src/service.zig) |
| Runtime/WAL/transport | [`../../../control/src/runtime.zig`](../../../control/src/runtime.zig) |
| Config/data_dir 与进程入口 | [`../../../control/src/config.zig`](../../../control/src/config.zig), [`../../../control/src/main.zig`](../../../control/src/main.zig) |
| Control module/wire/build | [`../../../control/src/root.zig`](../../../control/src/root.zig), [`../../../control/src/protobuf_wire.zig`](../../../control/src/protobuf_wire.zig), [`../../../control/build.zig`](../../../control/build.zig) |
| Control restart/failover tests | [`../../../control/src/runtime_integration_test.zig`](../../../control/src/runtime_integration_test.zig), [`../../../control/src/integration_test.zig`](../../../control/src/integration_test.zig) |
| Raftor/WAL/grpc transport | [`../../../raftz/src/raftor.zig`](../../../raftz/src/raftor.zig), [`../../../raftz/src/wal.zig`](../../../raftz/src/wal.zig), [`../../../raftz/src/rpc/grpc_lite_transport.zig`](../../../raftz/src/rpc/grpc_lite_transport.zig) |
| Raft core/RawNode/Ready | [`../../../raftz/src/raft.zig`](../../../raftz/src/raft.zig), [`../../../raftz/src/raw_node.zig`](../../../raftz/src/raw_node.zig), [`../../../raftz/src/ready_processor.zig`](../../../raftz/src/ready_processor.zig) |
| Raft StateMachine/membership | [`../../../raftz/src/state_machine.zig`](../../../raftz/src/state_machine.zig), [`../../../raftz/src/cluster_membership.zig`](../../../raftz/src/cluster_membership.zig) |
| Raft queue/snapshot config | [`../../../raftz/src/raftor_config.zig`](../../../raftz/src/raftor_config.zig), [`../../../raftz/src/proposal_queue.zig`](../../../raftz/src/proposal_queue.zig), [`../../../raftz/src/wal/snapshot_store.zig`](../../../raftz/src/wal/snapshot_store.zig) |
| Raft request/proposal tracking | [`../../../raftz/src/request_context.zig`](../../../raftz/src/request_context.zig), [`../../../raftz/src/proposal_tracker.zig`](../../../raftz/src/proposal_tracker.zig) |
| Raft storage/transport abstraction | [`../../../raftz/src/storage.zig`](../../../raftz/src/storage.zig), [`../../../raftz/src/transport.zig`](../../../raftz/src/transport.zig) |
| Segmented WAL internals | [`../../../raftz/src/wal/segment.zig`](../../../raftz/src/wal/segment.zig), [`../../../raftz/src/wal/segment_manager.zig`](../../../raftz/src/wal/segment_manager.zig), [`../../../raftz/src/wal/metadata_store.zig`](../../../raftz/src/wal/metadata_store.zig) |
| Raft multi-node/grpc tests | [`../../../raftz/tests/multi_node_test.zig`](../../../raftz/tests/multi_node_test.zig), [`../../../raftz/tests/grpc_raftor_test.zig`](../../../raftz/tests/grpc_raftor_test.zig) |
| grpc-lite API/TLS boundaries | [`../../../grpc-lite/src/channel.zig`](../../../grpc-lite/src/channel.zig), [`../../../grpc-lite/src/server.zig`](../../../grpc-lite/src/server.zig) |
| grpc-lite streaming/metadata/deadline | [`../../../grpc-lite/src/stream.zig`](../../../grpc-lite/src/stream.zig), [`../../../grpc-lite/src/metadata.zig`](../../../grpc-lite/src/metadata.zig), [`../../../grpc-lite/src/deadline.zig`](../../../grpc-lite/src/deadline.zig) |
| grpc-lite interoperability | [`../../../grpc-lite/tests/official/README.md`](../../../grpc-lite/tests/official/README.md) |

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
| Transaction/Store | [`../../../cawfs/src/transaction.zig`](../../../cawfs/src/transaction.zig), [`../../../cawfs/src/store.zig`](../../../cawfs/src/store.zig) |
| SCSI CAW/whole-LUN transport | [`../../../cawfs/src/scsi.zig`](../../../cawfs/src/scsi.zig), [`../../../cawfs/src/linux_sg_io.zig`](../../../cawfs/src/linux_sg_io.zig) |
| Mutable data/allocator | [`../../../cawfs/src/data_block.zig`](../../../cawfs/src/data_block.zig), [`../../../cawfs/src/extent_allocator.zig`](../../../cawfs/src/extent_allocator.zig) |
| Filesystem/format/maintenance | [`../../../cawfs/src/filesystem.zig`](../../../cawfs/src/filesystem.zig), [`../../../cawfs/src/filesystem_format.zig`](../../../cawfs/src/filesystem_format.zig), [`../../../cawfs/src/maintenance.zig`](../../../cawfs/src/maintenance.zig) |
| SCSI immutable Store | [`../../../cawfs/src/scsi_store.zig`](../../../cawfs/src/scsi_store.zig), [`../../../cawfs/src/immutable_extent.zig`](../../../cawfs/src/immutable_extent.zig) |

## 尚无实现

- Zettide iSCSI target/publication lifecycle。
- qtr managed NVMf-first backend、PVE plugin、CSI driver。
- NFS multi-member Pool export 与四前端真实多物理盘总 gate。
- Tier 2 online Pool/protection migration product lifecycle。
- Tier 3 vendor-specific Replica NVMf、commit evidence、epoch fencing、failover/repair。
- 生产级双向认证、细粒度授权与 credential rotation。
