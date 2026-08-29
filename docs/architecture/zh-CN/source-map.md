# 源码映射

本页只把本仓库拥有的“当前/部分/目标”映射到源码入口。第三方 API、enum 或 test harness 不单独证明产品能力。qtr、PVE 和 etz 等外部项目只作为契约边界出现，不链接其源码或维护其实现状态。

## 工作区入口

| 主题 | 文件 |
| --- | --- |
| 整体组件与 storage direction | [`../../../README.md`](../../../README.md) |
| Zettide 当前能力与 gate | [`../../../README.md`](../../../README.md) |
| 组件依赖与目标分层 | [`component-dependencies.md`](component-dependencies.md) |
| Package split decisions | [`../../decisions/0001-data-node-naming-and-process-model.md`](../../decisions/0001-data-node-naming-and-process-model.md), [`../../decisions/0002-keep-storage-engine-cohesive.md`](../../decisions/0002-keep-storage-engine-cohesive.md) |
| Root component/test wiring | [`../../../build.zig`](../../../build.zig), [`../../../build/tests.zig`](../../../build/tests.zig), [`../../../build/benchmarks.zig`](../../../build/benchmarks.zig) |
| Independent storage-engine package | [`../../../libs/storage-engine/README.md`](../../../libs/storage-engine/README.md), [`../../../libs/storage-engine/build.zig`](../../../libs/storage-engine/build.zig), [`../../../libs/storage-engine/src/root.zig`](../../../libs/storage-engine/src/root.zig) |
| Data-node product package | [`../../../services/data-node/README.md`](../../../services/data-node/README.md), [`../../../services/data-node/data_node_root.zig`](../../../services/data-node/data_node_root.zig), [`../../../services/data-node/root.zig`](../../../services/data-node/root.zig) |
| 存储抽象与持久格式归属 | [`storage-foundation-map.md`](storage-foundation-map.md) |
| Pool、Member 与 Catalog 归属 | [`pool-member-catalog-map.md`](pool-member-catalog-map.md) |
| Blob 与 BlobFilesystem 归属 | [`blob-filesystem-map.md`](blob-filesystem-map.md) |
| Backend-neutral Filesystem API 归属 | [`filesystem-api-map.md`](filesystem-api-map.md) |
| FUSE、NFS 与 dufs Frontend 归属 | [`frontend-map.md`](frontend-map.md) |
| SPDK Backend 与 Export 归属 | [`spdk-adapter-export-map.md`](spdk-adapter-export-map.md) |
| Endpoint Lifecycle 与 Daemon 归属 | [`endpoint-lifecycle-map.md`](endpoint-lifecycle-map.md) |
| CLI 与 Data Node 产品 Composition 归属 | [`cli-data-node-composition-map.md`](cli-data-node-composition-map.md) |
| CSI Node service | [`../../../services/csi/README.md`](../../../services/csi/README.md), [`../../../services/csi/internal/driver/driver.go`](../../../services/csi/internal/driver/driver.go) |
| 控制面范围 | [`../../../services/controller/README.md`](../../../services/controller/README.md) |
| Raft API、安全与恢复 | [`../../../vendor/raftz/README.md`](../../../vendor/raftz/README.md), [`../../../vendor/raftz/src/root.zig`](../../../vendor/raftz/src/root.zig) |
| grpc-lite API 与限制 | [`../../../vendor/grpc-lite/README.md`](../../../vendor/grpc-lite/README.md), [`../../../vendor/grpc-lite/src/root.zig`](../../../vendor/grpc-lite/src/root.zig) |
| 虚拟化/CSI 目标契约 | [`13-virtualization-and-csi.md`](13-virtualization-and-csi.md) |
| TxFS 契约 | [`12-txfs-shared-qcow2.md`](12-txfs-shared-qcow2.md), [`../../../libs/txfs/README.md`](../../../libs/txfs/README.md) |

## Pool、BlobFilesystem 与 Catalog

| 主题 | 文件 |
| --- | --- |
| v3 format | [`../../../docs/v3-format.md`](../../../docs/v3-format.md) |
| Member format/topology/layout | [`../../../libs/storage-engine/src/v3/member_format.zig`](../../../libs/storage-engine/src/v3/member_format.zig), [`../../../libs/storage-engine/src/v3/pool_topology.zig`](../../../libs/storage-engine/src/v3/pool_topology.zig), [`../../../libs/storage-engine/src/v3/pool_layout.zig`](../../../libs/storage-engine/src/v3/pool_layout.zig) |
| Member bootstrap/storage | [`../../../libs/storage-engine/src/v3/member_bootstrap.zig`](../../../libs/storage-engine/src/v3/member_bootstrap.zig), [`../../../libs/storage-engine/src/v3/member.zig`](../../../libs/storage-engine/src/v3/member.zig), [`../../../libs/storage-engine/src/v3/storage.zig`](../../../libs/storage-engine/src/v3/storage.zig) |
| Provision/authority/member set | [`../../../libs/storage-engine/src/v3/pool_provision.zig`](../../../libs/storage-engine/src/v3/pool_provision.zig), [`../../../libs/storage-engine/src/v3/pool_authority.zig`](../../../libs/storage-engine/src/v3/pool_authority.zig), [`../../../libs/storage-engine/src/v3/pool_member_set.zig`](../../../libs/storage-engine/src/v3/pool_member_set.zig) |
| Membership/control history | [`../../../libs/storage-engine/src/v3/membership.zig`](../../../libs/storage-engine/src/v3/membership.zig), [`../../../libs/storage-engine/src/v3/pool_replicated_journal.zig`](../../../libs/storage-engine/src/v3/pool_replicated_journal.zig), [`../../../libs/storage-engine/src/v3/control_record.zig`](../../../libs/storage-engine/src/v3/control_record.zig) |
| Linux device safety/planning | [`../../../services/data-node/v3/linux_block_device.zig`](../../../services/data-node/v3/linux_block_device.zig), [`../../../services/data-node/v3/linux_pool_plan.zig`](../../../services/data-node/v3/linux_pool_plan.zig) |
| Pool data device/storage | [`../../../libs/storage-engine/src/v3/pool_data_device.zig`](../../../libs/storage-engine/src/v3/pool_data_device.zig), [`../../../libs/storage-engine/src/v3/pool_data_storage.zig`](../../../libs/storage-engine/src/v3/pool_data_storage.zig) |
| Scheduled data/blob layout | [`../../../libs/storage-engine/src/v3/pool_scheduled_data_device.zig`](../../../libs/storage-engine/src/v3/pool_scheduled_data_device.zig), [`../../../libs/storage-engine/src/v3/pool_blob_schedule.zig`](../../../libs/storage-engine/src/v3/pool_blob_schedule.zig) |
| BlobFilesystem | [`../../../libs/storage-engine/src/blob_filesystem.zig`](../../../libs/storage-engine/src/blob_filesystem.zig), [`../../../services/data-node/filesystem_target.zig`](../../../services/data-node/filesystem_target.zig) |
| FUSE frontend 与 Blob adapter | [`../../../services/data-node/linux_fuse.zig`](../../../services/data-node/linux_fuse.zig), [`../../../libs/storage-engine/src/blob_filesystem_adapter.zig`](../../../libs/storage-engine/src/blob_filesystem_adapter.zig) |
| Multi-Volume format | [`../../../docs/v3-multivolume-format.md`](../../../docs/v3-multivolume-format.md) |
| Catalog Volume/mutation | [`../../../libs/storage-engine/src/v3/pool_catalog_volume.zig`](../../../libs/storage-engine/src/v3/pool_catalog_volume.zig), [`../../../libs/storage-engine/src/v3/pool_catalog_mutation.zig`](../../../libs/storage-engine/src/v3/pool_catalog_mutation.zig) |
| Catalog graph/store/page | [`../../../libs/storage-engine/src/v3/pool_catalog_graph.zig`](../../../libs/storage-engine/src/v3/pool_catalog_graph.zig), [`../../../libs/storage-engine/src/v3/pool_catalog_store.zig`](../../../libs/storage-engine/src/v3/pool_catalog_store.zig), [`../../../libs/storage-engine/src/v3/pool_catalog_page.zig`](../../../libs/storage-engine/src/v3/pool_catalog_page.zig) |
| Local ReplicaEndpoint | [`../../../libs/storage-engine/src/v3/replica_endpoint.zig`](../../../libs/storage-engine/src/v3/replica_endpoint.zig) |
| Storage package | [`../../../libs/storage-engine/README.md`](../../../libs/storage-engine/README.md), [`../../../libs/storage-engine/build.zig`](../../../libs/storage-engine/build.zig) |
| Storage module root | [`../../../libs/storage-engine/src/root.zig`](../../../libs/storage-engine/src/root.zig) |
| Shared data-mode geometry | [`../../../libs/storage-engine/src/data_mode_geometry.zig`](../../../libs/storage-engine/src/data_mode_geometry.zig) |
| Engine v3 root | [`../../../libs/storage-engine/src/v3/root.zig`](../../../libs/storage-engine/src/v3/root.zig) |
| Legacy v3 compatibility entry | [`../../../libs/storage-engine/src/v3/root.zig`](../../../libs/storage-engine/src/v3/root.zig) |
| Data-node module root | [`../../../services/data-node/data_node_root.zig`](../../../services/data-node/data_node_root.zig) |
| Module boundary gate | [`../../../tests/module_roots.zig`](../../../tests/module_roots.zig) |

`ReplicaEndpoint` 是本地 vtable；v3 control journal 是 Pool control history，二者都不是 Tier 3 Replica protocol。

## Endpoint Daemon 与标准 NVMf

| 主题 | 文件 |
| --- | --- |
| Product endpoint daemon | [`../../../services/data-node/endpoint_daemon.zig`](../../../services/data-node/endpoint_daemon.zig) |
| Versioned owner-only Unix API | [`../../../services/data-node/endpoint_control.zig`](../../../services/data-node/endpoint_control.zig) |
| Persistent desired state/registry | [`../../../services/data-node/endpoint_registry.zig`](../../../services/data-node/endpoint_registry.zig) |
| Catalog endpoint backend | [`../../../services/data-node/spdk/catalog_endpoint_backend.zig`](../../../services/data-node/spdk/catalog_endpoint_backend.zig) |
| Catalog Volume to NVMf export | [`../../../services/data-node/spdk/catalog_nvmf_export.zig`](../../../services/data-node/spdk/catalog_nvmf_export.zig) |
| Shared iSCSI service/target wrapper | [`../../../services/data-node/spdk/iscsi_export.zig`](../../../services/data-node/spdk/iscsi_export.zig), [`../../../services/data-node/spdk/iscsi_export.c`](../../../services/data-node/spdk/iscsi_export.c) |
| Catalog Volume to iSCSI export | [`../../../services/data-node/spdk/catalog_iscsi_export.zig`](../../../services/data-node/spdk/catalog_iscsi_export.zig) |
| Standard NVMf TCP/RDMA export wrapper | [`../../../services/data-node/spdk/nvmf_tcp_export.zig`](../../../services/data-node/spdk/nvmf_tcp_export.zig), [`../../../services/data-node/spdk/nvmf_tcp_export.c`](../../../services/data-node/spdk/nvmf_tcp_export.c), [`../../../services/data-node/spdk/nvmf_tcp_export.h`](../../../services/data-node/spdk/nvmf_tcp_export.h) |
| Catalog async backend/provider bdev | [`../../../services/data-node/spdk/catalog_volume_backend.zig`](../../../services/data-node/spdk/catalog_volume_backend.zig), [`../../../services/data-node/spdk/provider_bdev.zig`](../../../services/data-node/spdk/provider_bdev.zig), [`../../../services/data-node/spdk/bdev_provider.c`](../../../services/data-node/spdk/bdev_provider.c) |
| Managed SPDK runtime | [`../../../services/data-node/spdk/runtime.zig`](../../../services/data-node/spdk/runtime.zig), [`../../../services/data-node/spdk/runtime.c`](../../../services/data-node/spdk/runtime.c) |
| SPDK bdev storage/dispatcher | [`../../../services/data-node/spdk/storage.zig`](../../../services/data-node/spdk/storage.zig), [`../../../services/data-node/spdk/bdev_dispatcher.c`](../../../services/data-node/spdk/bdev_dispatcher.c) |
| SPDK endpoint/provider C ABI | [`../../../services/data-node/spdk/bdev_endpoint.c`](../../../services/data-node/spdk/bdev_endpoint.c), [`../../../services/data-node/spdk/bdev_endpoint.h`](../../../services/data-node/spdk/bdev_endpoint.h), [`../../../services/data-node/spdk/bdev_provider.h`](../../../services/data-node/spdk/bdev_provider.h) |
| NVMe-oF initiator | [`../../../services/data-node/spdk/nvme_controller.zig`](../../../services/data-node/spdk/nvme_controller.zig), [`../../../services/data-node/spdk/nvme_controller.c`](../../../services/data-node/spdk/nvme_controller.c) |
| NVMf export tests | [`../../../tests/spdk_nvmf_export.zig`](../../../tests/spdk_nvmf_export.zig), [`../../../tests/spdk-nvmf-fio.sh`](../../../tests/spdk-nvmf-fio.sh), [`../../../tests/automation/nvmf-catalog-fio.yml`](../../../tests/automation/nvmf-catalog-fio.yml) |
| iSCSI Catalog fio profile | [`../../../tests/spdk-iscsi-fio.sh`](../../../tests/spdk-iscsi-fio.sh), [`../../../tests/automation/iscsi-catalog-fio.yml`](../../../tests/automation/iscsi-catalog-fio.yml) |
| vhost-user-blk | [`../../../services/data-node/spdk/catalog_vhost_export.zig`](../../../services/data-node/spdk/catalog_vhost_export.zig), [`../../../services/data-node/spdk/vhost_block_export.zig`](../../../services/data-node/spdk/vhost_block_export.zig) |
| Physical/scheduled Pool gates | [`../../../tests/physical-pool-fio.sh`](../../../tests/physical-pool-fio.sh), [`../../../tests/scheduled-pool-nvmf-fio.sh`](../../../tests/scheduled-pool-nvmf-fio.sh), [`../../../tests/scheduled-blob-pool-fuse-fio.sh`](../../../tests/scheduled-blob-pool-fuse-fio.sh) |
| Hardware/RDMA NVMf gates | [`../../../tests/automation/nvmf-catalog-optane-fio.yml`](../../../tests/automation/nvmf-catalog-optane-fio.yml), [`../../../tests/automation/nvmf-catalog-rxe-fio.yml`](../../../tests/automation/nvmf-catalog-rxe-fio.yml), [`../../../tests/automation/nvmf-scheduled-pool-rxe-fio.yml`](../../../tests/automation/nvmf-scheduled-pool-rxe-fio.yml) |

这些文件证明标准 host-facing Catalog NVMf 与 iSCSI target/export 及 endpoint daemon 已有部分实现。它们不证明外部 managed-consumer E2E、consumer access-generation fencing、真实四前端多盘 gate 或 Tier 3 internal Replica protocol。

## NFS Backend 与 FSAL

| 主题 | 文件 |
| --- | --- |
| NFS filesystem abstraction | [`../../../libs/storage-engine/src/nfs_filesystem.zig`](../../../libs/storage-engine/src/nfs_filesystem.zig) |
| Blob adapter | [`../../../libs/storage-engine/src/nfs_blob_adapter.zig`](../../../libs/storage-engine/src/nfs_blob_adapter.zig) |
| Stable NFS handle | [`../../../services/data-node/nfs_handle.zig`](../../../services/data-node/nfs_handle.zig) |
| Zig C ABI backend | [`../../../services/data-node/nfs_backend.zig`](../../../services/data-node/nfs_backend.zig), [`../../../services/data-node/nfs_backend.h`](../../../services/data-node/nfs_backend.h) |
| NFS-Ganesha module | [`../../../services/nfs-fsal/README.md`](../../../services/nfs-fsal/README.md), [`../../../services/nfs-fsal/main.c`](../../../services/nfs-fsal/main.c), [`../../../services/nfs-fsal/export.c`](../../../services/nfs-fsal/export.c), [`../../../services/nfs-fsal/handle.c`](../../../services/nfs-fsal/handle.c) |
| NFSv3 RPC gate | [`../../../tests/nfs-ganesha.sh`](../../../tests/nfs-ganesha.sh), [`../../../tests/automation/blob-pool-nfs-fio.yml`](../../../tests/automation/blob-pool-nfs-fio.yml) |

当前 backend/FSAL 只打开 standalone regular-file target 或一个 Pool Member，
不组装多成员 Pool，因此 NFS 状态是“部分”。

## CSI

| 主题 | 文件 |
| --- | --- |
| FUSE CSI Node service | [`../../../services/csi/internal/driver/driver.go`](../../../services/csi/internal/driver/driver.go) |
| Process entry | [`../../../services/csi/cmd/zettide-csi-node/main.go`](../../../services/csi/cmd/zettide-csi-node/main.go) |
| Unit tests | [`../../../services/csi/internal/driver/driver_test.go`](../../../services/csi/internal/driver/driver_test.go) |
| Container | [`../../../services/csi/Dockerfile`](../../../services/csi/Dockerfile) |
| FUSE kind gate | [`../../../tests/fuse-csi-kind.sh`](../../../tests/fuse-csi-kind.sh), [`../../../tests/automation/csi-fuse-kind.yml`](../../../tests/automation/csi-fuse-kind.yml) |
| NFS CSI compatibility gate | [`../../../tests/nfs-csi-kind.sh`](../../../tests/nfs-csi-kind.sh), [`../../../tests/automation/csi-nfs-kind.yml`](../../../tests/automation/csi-nfs-kind.yml) |

当前 Zettide CSI binary 只实现静态 regular Blob file 的 Identity 与有限 Node service。NFS gate 使用上游 NFS CSI driver；两者都不证明 Controller、dynamic provisioning、block CSI 或多成员 NFS 已实现。

## zettide-controller / raftz / grpc-lite

| 主题 | 文件 |
| --- | --- |
| Controller protobuf | [`../../../services/controller/proto/zettide/controller/v1/controller.proto`](../../../services/controller/proto/zettide/controller/v1/controller.proto) |
| State machine/snapshot/idempotency | [`../../../services/controller/src/state_machine.zig`](../../../services/controller/src/state_machine.zig) |
| Heartbeat | [`../../../services/controller/src/heartbeat.zig`](../../../services/controller/src/heartbeat.zig) |
| RPC/ReadIndex | [`../../../services/controller/src/service.zig`](../../../services/controller/src/service.zig) |
| Runtime/WAL/transport | [`../../../services/controller/src/runtime.zig`](../../../services/controller/src/runtime.zig) |
| Config/data_dir 与进程入口 | [`../../../services/controller/src/config.zig`](../../../services/controller/src/config.zig), [`../../../services/controller/src/main.zig`](../../../services/controller/src/main.zig) |
| Controller module/wire/build | [`../../../services/controller/src/root.zig`](../../../services/controller/src/root.zig), [`../../../services/controller/src/protobuf_wire.zig`](../../../services/controller/src/protobuf_wire.zig), [`../../../services/controller/build.zig`](../../../services/controller/build.zig) |
| Controller restart/failover tests | [`../../../services/controller/src/runtime_integration_test.zig`](../../../services/controller/src/runtime_integration_test.zig), [`../../../services/controller/src/integration_test.zig`](../../../services/controller/src/integration_test.zig) |
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

Vendored API/target 只证明依赖中存在相应原语，不证明 Zettide 已封装产品 lifecycle。当前 Zettide 已封装标准 Catalog NVMf 与 iSCSI exports；consumer-bound Publication generation 和 Tier 3 vendor-specific Replica target 仍未实现。

当前 control Volume 是 metadata intent；无 placement、Replica/Allocation mutation、lease、publication authority 或 reconciliation。

## TxFS

| 主题 | 文件 |
| --- | --- |
| Transaction/Store | [`../../../libs/txfs/src/transaction.zig`](../../../libs/txfs/src/transaction.zig), [`../../../libs/txfs/src/store.zig`](../../../libs/txfs/src/store.zig) |
| SCSI CAW/whole-LUN transport | [`../../../libs/txfs/src/scsi.zig`](../../../libs/txfs/src/scsi.zig), [`../../../libs/txfs/src/linux_sg_io.zig`](../../../libs/txfs/src/linux_sg_io.zig) |
| Mutable data/allocator | [`../../../libs/txfs/src/data_block.zig`](../../../libs/txfs/src/data_block.zig), [`../../../libs/txfs/src/extent_allocator.zig`](../../../libs/txfs/src/extent_allocator.zig) |
| Filesystem/format/maintenance | [`../../../libs/txfs/src/filesystem.zig`](../../../libs/txfs/src/filesystem.zig), [`../../../libs/txfs/src/filesystem_format.zig`](../../../libs/txfs/src/filesystem_format.zig), [`../../../libs/txfs/src/maintenance.zig`](../../../libs/txfs/src/maintenance.zig) |
| SCSI immutable Store | [`../../../libs/txfs/src/scsi_store.zig`](../../../libs/txfs/src/scsi_store.zig), [`../../../libs/txfs/src/immutable_extent.zig`](../../../libs/txfs/src/immutable_extent.zig) |

## 尚无实现

- Consumer-bound NVMf/iSCSI Publication generation 与 managed external attachment。
- qtr/PVE 等外部 managed backend（不属于本仓库）。
- CSI Controller、dynamic provisioning、block CSI 和 managed NFS lifecycle。
- NFS multi-member Pool export 与四前端真实多物理盘总 gate。
- Tier 2 online Pool/protection migration product lifecycle。
- Tier 3 vendor-specific Replica NVMf、commit evidence、epoch fencing、failover/repair。
- 生产级双向认证、细粒度授权与 credential rotation。
