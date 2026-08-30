# 范围与状态

> 状态：Tier 1 部分；Tier 2/3 目标能力具有不同程度的库与控制面基础

## 系统边界

Zettide 的第一条交付边界是**单节点、多物理磁盘存储接管**，不是某一个 frontend：

- 同机：Zettide 与 qtr、PVE 等虚拟化宿主机同机，独占接管本机多块物理盘。
- 独立节点：一个 Zettide data node 独占接管多块物理盘，经存储网络服务一个或多个虚拟化宿主机。

Tier 1 同时覆盖 Catalog Volume block model 与 BlobFilesystem model。两者都建立在由多个独立物理磁盘组成的 Pool 上，但 Pool data mode 不同，不允许 block 与 filesystem frontend 并发暴露同一对象。

Tier 2 在该单节点基线上增加动态成员、在线容量/保护迁移、multi-Volume
publication/attachment 治理和更完整的平台生命周期；基本 qtr managed
attachment 已属于 Tier 1 门槛。Tier 3 才增加跨 data node Replica、
fencing、failover、repair 和 republish。

独立 TxFS shared-file profile 见 [TxFS 共享 qcow2 接入](12-txfs-shared-qcow2.md)；它不替代 Catalog block publication。

## Tier 完成标准

| Tier | 状态 | 完成标准 |
| --- | --- | --- |
| Tier 1 | 部分 | 四个基线 frontend 均通过真实多物理盘 gate；qtr 原生 managed backend 以 NVMf-first、iSCSI fallback 完成 create/publish/attach/restart/detach E2E；同机与独立节点拓扑均验证 |
| Tier 2 | 目标 | 动态 Pool、可恢复在线扩容/保护迁移、multi-Volume 与 publication 治理完成；平台生命周期可扩展，且不重复计算 Tier 1 qtr gate |
| Tier 3 | 目标 | 跨节点默认 3/2 持久提交、lease/epoch fencing、storage failover、repair 和调用方指定 host 的 republish E2E |

单文件、单盘、loop/synthetic member 都继续可用，但不满足 Tier 1 完成标准。

## 前端状态

| 能力 | 状态 | 当前事实 | 缺口 |
| --- | --- | --- | --- |
| FUSE + BlobFilesystem | 当前 | foreground FUSE/POSIX frontend 已覆盖 regular Blob file 与多成员 raw Blob Pool | 完整真实多盘 Tier 1 gate 仍需与其余 frontend 一起完成 |
| NFS + BlobFilesystem | 部分 | NFSv3 backend、`FSAL_ZETTIDE` 和真实 RPC gate 已存在 | 当前 FSAL 只打开一个 Pool Member；无多成员准入 |
| 标准 NVMf + Catalog Volume | 部分 | TCP/RDMA Catalog export、endpoint registry、持久 desired state、owner-only Unix control API 和 endpoint daemon 已存在 | 无 qtr managed NVMf E2E；无四前端真实多盘完整 gate |
| iSCSI + Catalog Volume | 部分 | Zettide 已有 SPDK shared service、Catalog target/LUN export、endpoint locator/lifecycle 和 `iscsi-catalog-fio` 自动化 profile | 无 consumer-bound access generation、managed attachment 和真实多物理盘 Tier 1 总 gate |
| 外部虚拟化 managed backend | 目标 | qtr/PVE 不在本仓库实现或验证 | 需要 Zettide Volume/publication identity、managed NVMf-first/iSCSI-fallback attachment 和 restart reconciliation |
| PVE integration contract | 目标 | 外部项目状态不由本仓库维护 | 一等后续集成目标，优先于完整 CSI；不阻塞 Tier 1 |
| CSI integration | 部分 | 本仓库已有静态 regular Blob file 的 FUSE CSI Node service、持久 mount intent/recovery 和 FUSE/NFS kind profiles | 无 Controller service、动态 provisioning、block CSI、NFS export lifecycle 或多成员 FUSE Pool path |

## 存储与控制基础

| 能力 | 状态 | 当前事实 |
| --- | --- | --- |
| 本地 Pool 与格式 | 当前/部分 | Member v3、authority scan、control journal、Blob data mode、多成员复制和 scheduled layout 已有路径；动态生命周期未产品化 |
| Catalog | 部分 | multi-Volume catalog、extent mapping、writable backend 和 endpoint registry 已存在；在线扩容/保护迁移未接线 |
| SPDK | 部分 | managed runtime、provider bdev、Catalog NVMf TCP/RDMA export、vhost-user-blk 与 initiator wrapper 有 focused tests |
| `zettide-controller` | 基础 | Pool/Node/Member/Volume metadata、heartbeat、Raft/WAL/snapshot/ReadIndex、placement、authority/lease state machine 与 leader reconciliation 已接线；公开 Lease/Publication API 仍不存在 |
| Tier 3 Replica protocol | 基础 | 三节点 file Replica fencing/authority 生命周期与 restart failover 已验证；controller 配置 canonical three-Member set，daemon 组合持久 participant、active-Replica file apply 与共享 fence/replay gate；daemon 可启动独立 pairwise-HMAC Replica gRPC listener 并持久注册 endpoint；contracts 另有 backend-neutral coordinator journal，能在任何外部 PREPARE 前持久固定 two-witness intent，并 strict-verify/保存独立 Ed25519 PREPARE/COMMIT evidence、certificate 与 partial-COMMIT 供同 state directory 重试，尚未接入 production coordinator fanout；participant certificate 与 Replica RPC 已携带并验证签名，controller 固定 generation-1 key provenance；仍无 confidentiality、key rotation/revocation、vendor-specific NVMf commands、production 跨节点 coordinator、quorum recovery/repair 或 publication |
| TxFS shared qcow2 | 部分 | transaction、SCSI CAW/data transport、voting 和 allocator 基础存在；POSIX/FUSE 与 qtr 未接线 |

## 两种 Pool

仓库目前存在两个不同层次的 Pool：

- **控制面 Pool**：跨节点资源、策略和 Volume 的逻辑边界。
- **本地 v3 Pool**：由一个或多个 Member 构成的本地持久化集合，保存 topology、layout 和 control journal。

目标架构允许一个控制面 Pool 聚合多个节点的本地资源。二者必须通过稳定 ID 和显式注册关系绑定，不能依赖名称或设备路径隐式关联。

## 两种 NVMf

- **标准 host-facing NVMf publication**：Catalog Volume 到虚拟化 host 的标准 NVMe block interface，支持 TCP/RDMA；当前已有部分实现。
- **内部 Replica transport**：Tier 3 primary 到 Replica 的协议，需要携带 Zettide epoch、sequence 和 commit evidence；当前 controller 已配置 canonical set，daemon 已有 node-local participant manager、gated file apply、显式 plaintext-development opt-in、receiver-scoped key file 与持久注册的独立 Replica endpoint。Backend-neutral coordinator journal 已证明 fixed witness/unknown-result/restart ordering，并持久 strict-verified Ed25519 evidence；签名现已进入 participant certificate/ReplicaTransport，daemon 注册 controller-pinned generation-1 public key。但尚未接线 outbound key/topology route 或 client write RPC，因此仍没有 key rotation/revocation、confidentiality、真实跨节点 coordinator 或最终 NVMf transport。

标准 NVMf export 的存在不证明 Tier 3 Replica protocol 已实现；反过来，Tier 3 设计也不能把标准 host-facing NVMf 写成仅供内部使用。

## 组件边界

- `zettide` 当前拥有本地 Pool、BlobFilesystem、FUSE、NFS backend、Catalog endpoint daemon，以及标准 NVMf、iSCSI 和 vhost export primitives。
- `services/csi` 当前拥有静态 FUSE CSI Node service；完整 Controller/block/NFS CSI lifecycle 为目标。
- `qtr` 与 PVE 是外部消费者；本仓库只冻结集成契约，不维护或验证其当前实现状态。
- `zettide-controller` 当前拥有部分 durable metadata 和 Raft runtime；不与当前 endpoint daemon 形成产品 E2E。

## 当前实现边界

### zettide-controller

当前具备：

- Pool protobuf 模型、确定性命令 apply、Pool ID/name 索引、容量上限和输入校验。
- durable Node 注册、ID 索引、cluster binding、容量上限和输入校验。
- durable Member 注册、本地 set/slot 唯一性、Pool/Node 绑定和不可变 allocation geometry。
- durable Volume metadata intent、固定 3/2/1 保护参数、条件删除和永久有界 tombstone；CreateVolume 只返回 `PROVISIONING` intent，不执行 placement 或数据面 I/O。
- ReplicaPlacement、ReplicaAllocation 和 VolumeAttachment 的 durable schema、索引与恢复不变量；当前没有创建这些 child resource 的 mutation。
- Pool/Node/Member/Volume 共享 request ID history、幂等域、语义指纹和跨类型冲突检测。
- Create/Get/List Pool、Register/Get/List Node、Register/Get/List Member、Create/Get/Delete Volume 的 grpc-lite handlers；mutation 成功来自 committed apply，一致读取经过 ReadIndex。
- Report/Get Heartbeat grpc-lite handlers；durable binding 校验和易失 observation 访问在 ReadIndex callback 中串行执行。
- leader-local heartbeat store；限制 10,000 Nodes、10,000 Member observations 和每次 256 Members，推荐每 1 秒上报，5 秒后 stale。
- Heartbeat 不进入 WAL/snapshot；leader 切换、任期变化或 snapshot restore 后清空并要求重新上报。
- v5 状态快照、v2/v3/v4 兼容读取、原子恢复、损坏快照拒绝、持久 WAL、静态多 voter grpc-lite Raft transport 和可运行 daemon。
- Pool/Node/Member/Volume 的 snapshot/WAL 恢复和三 voter leader failover/restart 集成测试，包括 Volume tombstone、幂等重放、heartbeat 清空和重新上报。

当前不具备：

- Replica/Allocation/Attachment mutation、placement、extent allocator、lease、publication authority 和 reconciliation。
- Member lifecycle、当前 topology/authority、路径、Replica 和健康观测。
- Node 能力更新、隔离和注销。
- 动态 Raft 成员管理、认证授权、mTLS、健康检查和生产运维接口。

### zettide

当前具备：

- regular Blob file、raw-disk Blob Pool、Blob stores、BlobFilesystem 和 backend-neutral Linux FUSE/POSIX frontend。
- 本地 raw Pool 的安全创建、检查、打开和挂载，以及 Member v3 双头部、control journal、authority scan 和故障冻结。
- 单成员无保护路径和三份本地 scheduled replicas；复制写入/同步等待所有涉及的本地 Replica，任一失败会 sticky freeze 后续写入，不提供多数派确认或降级写。
- NFSv3 backend 与 `FSAL_ZETTIDE`；当前 FSAL 只打开单个 Pool Member。
- multi-Volume Catalog、extent mapping、Catalog data lease 和 writable backend。
- endpoint registry、持久 desired state、owner-only Unix control API 和 daemon；每个 Pool 同时最多一个 endpoint，全 registry 最多 1024 endpoints。
- endpoint 当前记录 endpoint/Pool/Volume/frontend 和 locator，但没有 platform consumer identity 或 publication access generation。
- managed SPDK runtime、bdev dispatcher、Catalog NVMf TCP/RDMA 与 iSCSI target exports、NVMe-oF initiator、异步 bdev provider 和 vhost-user-blk lifecycle 的 focused paths。

当前不具备：

- 统一 DataService/Node Agent、grpc-lite control client 或节点注册。
- consumer-bound Publication API、access-generation fencing、外部虚拟化 managed adapter 或完整 CSI Controller/block/NFS lifecycle。
- NFS 多成员产品路径、动态扩容、每 Volume 保护迁移和对应产品命令。
- Tier 3 多数派数据提交、primary failover、Replica protocol 和后台 repair。

### 外部虚拟化消费者

qtr 与 PVE 不属于本仓库的构建或测试生命周期。本架构只要求外部 adapter 使用稳定
Volume/Publication/consumer identity，执行 managed NVMf-first、iSCSI-fallback attachment，并在未知响应和
重启后 reconciliation；其当前实现状态必须由各自仓库维护。

## 成熟度判断

1. 非测试代码和局部测试只能证明组件能力。
2. protocol export 可运行不等于 managed consumer lifecycle 已完成。
3. 单成员或 synthetic/loop gate 不等于真实多物理盘 Tier 1 gate。
4. schema、format 或 vendored third-party target 不等于产品实现。
5. 本文不把任何路径描述为生产可用。
