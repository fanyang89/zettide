# Zettide 存储架构

本文档描述 Zettide 从单节点多物理盘接管，到在线服务治理，再到跨节点高可用存储的当前实现、目标架构与关键不变量。

> Zettide 仍处于主动开发阶段。本文使用“当前”“部分”“目标”和“非目标”区分成熟度；目标设计不表示已端到端交付，更不表示生产可用。

## 架构主线

- Tier 1：一个 Zettide 节点接管由多个独立物理磁盘组成的 Pool，并向虚拟化与文件系统消费者提供基线前端。
- Tier 2：在 Tier 1 上增加动态 Pool、在线容量/保护迁移、multi-Volume 服务治理，以及更完整的 publication/attachment 生命周期。
- Tier 3：增加跨 storage node 同步复制、fencing、storage failover、repair 和 republish。

Tier 1 支持同机和独立单节点两种部署。虚拟化是一等消费者：qtr 原生 managed backend 是 Tier 1 完成门槛；PVE 和其他虚拟化平台是一等后续集成目标，优先于 CSI，但不阻塞 Tier 1；CSI 是次级、非阻塞集成目标。

## 基线前端

| 前端 | 数据模型 | 角色 | 当前状态 |
| --- | --- | --- | --- |
| 标准 NVMf TCP/RDMA | Catalog Volume | 首选 host-facing block publication | 部分：endpoint daemon 与 export 已存在；无 qtr managed E2E 和真实多物理盘完整准入 |
| iSCSI | Catalog Volume | fallback/compatibility block protocol | 目标：Zettide target 尚未实现；qtr 仅有手动外部 initiator |
| NFS | BlobFilesystem | network filesystem | 部分：NFSv3 backend/FSAL 已存在，当前只打开单成员 |
| FUSE | BlobFilesystem | local filesystem | 当前：多成员 Blob Pool 路径已存在 |

Catalog 与 Blob 是不同 Pool data mode。NVMf/iSCSI 不与 NFS/FUSE 并发访问同一数据对象。单文件、loop/synthetic member 和单盘仍可用于开发与专项验证，但不能单独满足 Tier 1。

标准 host-facing NVMf publication 与 Tier 3 内部 vendor-specific Replica NVMf transport 是两套协议语义。前者当前已有部分实现；后者尚未实现，不能因共享 SPDK/NVMf transport 而混为一谈。

## 范围

- `zettide`：Pool、本地数据模型、FUSE/NFS frontend、Catalog endpoint daemon 与标准 NVMf publication。
- `zettide-control`：Tier 3 权威元数据与协调基础。
- `raftz` 与 `grpc-lite`：共识、恢复和控制 RPC。
- qtr/PVE/CSI：消费者 adapter、publication、attachment 与 mount 生命周期边界。
- `zettide-txfs`：独立 shared qcow2 文件路径，不替代 Catalog block publication。

本书覆盖存储系统及其与 qtr、PVE、CSI 的直接 publication、attachment、export 和 mount 边界。除这些存储接入外，计算调度、VM 生命周期、自动 VM 重启、覆盖网络、Web UI、计费和完整发行版生命周期不在本书范围内。Tier 3 可以把 Volume republish 到调用方指定的 host，但不负责选择该 host 或重启 workload。

## 目录

1. [范围与状态](00-scope-and-status.md)
2. [目标与原则](01-goals-and-principles.md)
3. [系统架构](02-system-architecture.md)
4. [领域模型](03-domain-model.md)
5. [控制面](04-control-plane.md)
6. [数据面](05-data-plane.md)
7. [I/O 与控制流程](06-io-and-control-flows.md)
8. [一致性与 Fencing](07-consistency-and-fencing.md)
9. [故障与恢复](08-failure-and-recovery.md)
10. [部署与网络](09-deployment-and-networking.md)
11. [安全边界](10-security.md)
12. [演进路线图](11-evolution-roadmap.md)
13. [TxFS 共享 qcow2 接入](12-txfs-shared-qcow2.md)
14. [虚拟化与 CSI](13-virtualization-and-csi.md)
15. [术语表](glossary.md)
16. [源码映射](source-map.md)

## 状态标记

| 标记 | 含义 |
| --- | --- |
| 当前 | 已存在实现，并有测试或可执行构建路径 |
| 部分 | 类型或局部机制已实现，但端到端能力尚未形成 |
| 目标 | 已选择的架构方向，尚未完成实现 |
| 非目标 | 当前阶段明确不处理 |

## 文档约定

- Pool Member topology 表示容量和故障边界；Volume protection policy 表示数据副本目标。
- 控制面 Pool 是跨节点资源、策略和 Volume 的逻辑边界；`zettide` 本地 v3 Pool 是由本地 Member、topology、layout 和 control journal 构成的持久集合。二者必须通过稳定 ID 和显式注册关系绑定，不能按名称或设备路径隐式等同。
- `Raft leader`、Volume `primary` 与 publication target 是不同角色。
- Volume write epoch、publication access generation、Replica generation、Raft term 和本地 Pool membership epoch 是不同版本域。
- NVMf NQN/NSID/controller、iSCSI portal/IQN/LUN/session、NFS export path、FUSE mount path 和 `/dev/...` 都是可重建 locator/runtime state，不是资源身份。
- “持久确认”要求满足底层已经验证的 flush/FUA 语义；进入内存、发送队列、NVMf queue 或设备易失缓存都不构成持久确认。
- 当前安全模型是可信隔离网络，不是零信任网络。
- 文档与实现冲突时，以源码、协议和测试为准；入口见 [源码映射](source-map.md)。
