# 0003：存储产品架构与能力边界

- 状态：Accepted
- 范围：Zettide storage repository 的数据模型、frontend、Tier、组件 ownership 与外部消费者边界
- 前置决策：[0001：存储节点命名与进程模型](0001-storage-node-naming-and-process-model.md)、
  [0002：首轮提取后保持单一 Storage Engine Package](0002-keep-storage-engine-cohesive.md)

## 背景

仓库已经同时包含本地多盘 Pool、Catalog Volume、BlobFilesystem、多个 frontend、控制面基础、
CSI adapter 和 TxFS。过去的架构文档混合了当前状态、迁移步骤和目标设计，导致局部实现容易被
误写成完整产品能力，也使 iSCSI、CSI 等已经存在的组件仍被描述为“尚无实现”。

本决策冻结产品级架构边界。实现成熟度仍会变化，由
[范围与状态](../architecture/zh-CN/00-scope-and-status.md)维护；成熟度变化不自动改变本决策。

## 决策

### 1. 两种数据模型

Zettide 保留两个互不替代的数据模型：

| 数据模型 | 资源 | frontend |
| --- | --- | --- |
| Block | Catalog Volume | 标准 host-facing NVMf TCP/RDMA、iSCSI；vhost-user-blk 可作为同机优化 frontend |
| Filesystem | BlobFilesystem | NFS、FUSE |

Catalog 与 Blob 是不同 Pool data mode。不得把同一对象同时以 block 和 filesystem 语义写入；
CSI、虚拟化 adapter 或协议选择不能跨越该边界实现隐式 fallback。

NVMf 与 iSCSI locator、session 和授权各自独立，但必须绑定同一稳定 Volume/Publication identity。
NFS 与 FUSE 同样不能通过路径名称替代 BlobFilesystem identity 和 writer ownership。

### 2. Tier 是累积产品能力

- **Tier 1**：一个 Zettide storage node 独占接管多块独立物理盘，在同机或独立节点部署中提供
  Catalog 与 Blob 两种数据路径。四个基线 frontend 是 NVMf、iSCSI、NFS 和 FUSE。虚拟化的
  managed NVMf-first、iSCSI-fallback attachment 是 Tier 1 完成门槛。
- **Tier 2**：在 Tier 1 上增加动态 Pool membership、可恢复在线容量/保护迁移、multi-Volume
  服务治理和更完整的 publication/attachment lifecycle。
- **Tier 3**：增加跨 storage node Replica、持久多数派提交、lease/epoch fencing、storage
  failover、repair 和 caller-directed republish。

独立单节点部署仍属于 Tier 1，不因使用网络 frontend 自动成为 Tier 3。单文件、单盘、loop、
synthetic member、schema、codec 或专项 benchmark 都不能单独满足 Tier 完成标准。

### 3. 标准 publication 与内部复制协议分离

标准 host-facing NVMf/iSCSI publication 向 consumer 提供普通 block device。Tier 3 内部 Replica
transport 是独立协议，需要 Zettide write epoch、sequence、generation 和 commit evidence。
共享 SPDK、TCP、RDMA 或 NVMe transport 不允许两者共享 identity、授权域或成功语义。

控制面 Raft 只复制权威元数据，不进入正常 payload I/O 路径，也不能替代 Replica durable commit。

### 4. 组件与进程 ownership

| 路径/产物 | 固定职责 |
| --- | --- |
| `libs/storage-engine/` / `zettide_storage` | 进程内 backend-neutral storage engine、持久格式、Pool/Member/Catalog、Blob/BlobFilesystem 和 filesystem ports |
| `services/node/` / `zettide-node` | data-node product composition、DataService、Pool/endpoint reconciliation、Linux/SPDK/protocol adapters |
| `zettide` | operator-owned offline/foreground CLI；保留 format/check/inspect、foreground FUSE/dufs 和迁移期 endpoint compatibility |
| `services/controller/` / `zettide-controller` | Raft 权威元数据、placement/reconciliation/fencing 控制面 |
| `services/csi/` | Kubernetes CSI lifecycle adapter；不得定义新的数据格式或一致性模型 |
| `services/nfs-fsal/` | 独立 NFS-Ganesha 进程加载的 FSAL adapter |
| `libs/txfs/` | conditional-write shared-file engine；不替代 Catalog Volume block publication |
| `libs/data-service-contracts/` | controller/node 共享 RPC 与 authority/fencing contract；不依赖 storage engine |

一个 writable Pool、Catalog、endpoint 或 SPDK runtime 在同一时刻只能有一个进程 owner。
`zettide_storage` 不启动 socket、不解析产品 CLI、不处理进程信号，也不依赖 controller、CSI、SPDK、
FUSE 或 NFS-Ganesha。

### 5. Consumer 与仓库边界

`qtr`、PVE 和其他虚拟化系统是 Zettide 的外部 consumer。Zettide 定义稳定的 Volume、Publication、
Export、generation、locator 和错误契约，但不在本仓库维护 qtr/etz 源码、构建、测试或当前实现状态。

`services/csi/` 属于本仓库，但 CSI 只是 lifecycle adapter：

- block 请求映射 Catalog Volume 和 NVMf/iSCSI；
- filesystem 请求映射 BlobFilesystem 和 NFS/FUSE；
- 只有已经实现并验证的 capability 可以对 Kubernetes 广告；
- CSI handle、Node 名称、service account、mount path 或 `/dev/...` 都不能替代 Zettide resource identity。

计算调度、VM 自动重启、Pod 重调度、Web UI、计费和覆盖网络不属于 storage repository。
Tier 3 republish 只把 storage publication 激活到调用方指定的 host，不选择 host 或重启 workload。

### 6. 状态与规范分离

本决策冻结架构方向，不把尚未实现的目标描述为当前能力。状态汇总遵循以下规则：

- “当前”必须有仓库内源码和构建/测试入口；
- “部分”表示局部机制或专项 gate 已存在，但完整 lifecycle、故障语义或 E2E 尚未形成；
- vendored third-party capability 不等于 Zettide product capability；
- 源码和测试可以证明状态文档过期，但不能静默改变本 ADR 的数据模型、Tier 或 ownership；
- 若实现需要违反本 ADR，必须先提交新的 ADR 取代相应条款。

## 结果

- 架构书可以更新实现成熟度，而无需反复重写产品边界。
- iSCSI、CSI 等局部实现按证据标记为“部分”，不再被误写为完全不存在，也不因此被宣称为 Tier 完成。
- 迁移计划、性能报告和仓库历史不再承担规范职责。
- qtr/etz 只作为外部集成边界出现，不再使用本仓库内不存在的源码链接或测试命令。

## 被拒绝的方案

### 以 frontend 定义独立产品和数据模型

拒绝。NVMf/iSCSI 都消费 Catalog Volume，NFS/FUSE 都消费 BlobFilesystem；按协议复制数据模型会制造
不兼容 identity、持久性和恢复语义。

### 将 CSI 作为第五种数据面

拒绝。CSI 映射 Kubernetes lifecycle，不拥有新的 on-media format、commit 或 fencing 语义。

### 标准 NVMf 直接充当 Tier 3 Replica protocol

拒绝。标准 block command 不携带 Zettide epoch、sequence、generation 和 commit evidence。

### 由源码现状隐式改变架构

拒绝。实现偏差应作为缺陷、状态更新或新 ADR 处理；不能因为某个 adapter 先落地就改变 Tier、
数据模型或 resource ownership。
