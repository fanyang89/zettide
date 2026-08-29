# 目标与原则

> 状态：目标设计；本地格式、FUSE、多成员 Blob Pool、标准 NVMf export 和控制面基础已部分体现这些原则

## 分层目标

### Tier 1：单节点多盘接管

- 一个 Zettide 节点独占管理多个独立物理磁盘。
- 同时支持同机虚拟化宿主机与独立 storage node 两种拓扑。
- Catalog Volume 通过标准 NVMf TCP/RDMA 首选发布，iSCSI 提供兼容 fallback。
- BlobFilesystem 通过 NFS 提供网络文件系统，通过 FUSE 提供本地文件系统。
- qtr 原生 managed backend 完成 NVMf-first、iSCSI fallback 的幂等 attachment lifecycle。
- 四前端均以真实多物理盘 Pool 通过准入；单文件或单盘仅作为辅助路径。

Tier 1 不承诺 storage node 故障后的服务连续性。它的故障边界是单个 storage node 及其介质，局部多盘保护只能覆盖经 profile 验证的设备故障。

### Tier 2：在线演进与服务治理

- Pool 成员可进入 joining/active/draining 生命周期。
- 在线增加容量不隐式改变已有 Volume 的 protection policy。
- Pool default 与 per-Volume override 分离 desired、current 和 migration phase。
- 多 Volume、publication、attachment、配额、观测与升级生命周期统一治理。
- PVE 和其他平台 adapter 可在此扩展，但 Tier 2 不重复把 qtr 基本单机接管作为新 gate。

### Tier 3：跨节点高可用

- 默认三个 Replica 跨 storage node 故障域放置，2/3 持久提交。
- 每个可写 Volume 只有一个 primary，并由 lease 与 write epoch fencing。
- `zettide-controller` 通过 Raft 保存权威元数据。
- 内部 vendor-specific Replica NVMf transport 承载带 epoch/sequence/commit evidence 的复制 I/O。
- storage failover、repair 与 caller-directed republish 不等于 VM 调度或自动重启。

## 消费者目标

- qtr 是 Tier 1 阻塞性一等外部消费者；其实现与测试由独立仓库维护。
- PVE 与其他虚拟化平台是一等后续外部集成目标，优先于完整 CSI，但不阻塞 Tier 1。
- CSI 是次级、非阻塞集成；当前已有静态 FUSE Node service，后续 Controller、block 与 NFS lifecycle
  仍只映射 Kubernetes 生命周期到既有 Zettide 资源与 frontend。
- TxFS shared qcow2 是独立 filesystem profile，不改变 Catalog Volume 路线。

## 设计原则

### 1. 数据模型先于协议

NVMf/iSCSI 只访问 Catalog Volume；NFS/FUSE 只访问 BlobFilesystem。协议不能让同一对象同时获得 block 与 filesystem 语义。

### 2. Pool 必须表达真实故障边界

Member 使用稳定身份并对应独立介质。单文件、loop device 或同一物理盘的多个 slice 不能冒充 Tier 1 多物理盘 gate。

### 3. 标准 NVMf 与 Replica NVMf 分离

Host-facing NVMf 是标准 block publication；Tier 3 Replica NVMf 是尚未实现的 vendor-specific internal protocol。两者具有不同 NQN、身份、授权、generation 和恢复规则。

### 4. 稳定身份不依赖 locator

Pool、Volume、Filesystem、Publication、Attachment、Node、Member 和 Replica 使用稳定 ID。NQN/NSID、IQN/LUN、portal、export path、mount path 和 `/dev/...` 是可重建状态。

### 5. Intent 先于副作用

Managed adapter 在 connect、mount 或修改 libvirt 前持久化 intent；未知结果使用相同 operation ID 查询或重试。Detach 先撤销消费者，再释放 session、mount 和 publication。

### 6. 权威、观测和持久事实分离

Desired state、runtime observation 与介质事实分别保存并通过 reconciliation 收敛。“命令已发送”不等于“数据可用”。

### 7. 容量与保护解耦

Pool topology 回答容量与故障边界；protection policy 回答目标副本。系统分别报告 desired protection、current protection 和 migration phase。

### 8. 不确定时 fail closed

无法证明身份、generation、lease、epoch、提交边界或持久性时停止新写入。当前本地 sticky write freeze 是局部实现。

### 9. 控制面不进入逐 I/O 路径

控制面处理低频生命周期与权威变化。标准 frontend 或 Tier 3 Replica data path 直接承载数据 I/O。

### 10. 有界资源与显式降级

队列、RPC、heartbeat、repair 和 migration 均有上限。Healthy、Degraded、ReadOnly、Unavailable 与 Fencing/Recovering/Repairing 分开报告。

### 11. 可验证后自动化

真实设备、进程崩溃、断网、重启、旧 session/controller 恢复和介质损坏 gate 必须先于自动 failover、repair 或生产声明。

### 12. 不夸大安全能力

TLS server authentication、Host NQN、CHAP name、UID/GID、Node ID 和 CSI service account 名称都不天然等于完整认证授权。当前只允许可信隔离部署。

## 非目标

- 同一 Catalog Volume 与 BlobFilesystem 对象的跨模型并发访问。
- 多主写同一 Volume。
- 让 CSI 定义独立数据面或一致性语义。
- 由存储系统自动选择 VM host、迁移或重启 VM。
- 在 Tier 1/2 抵抗整个 storage node 故障。
- 跨地域同步复制。
- 纠删码数据路径。
- 让每次数据 I/O 经过 Raft。
- 在缺少 commit evidence 时按时间戳猜测 Tier 3 权威数据。
- 未经认证直接暴露到公网或不可信租户网络。

## 成功标准

Tier 1 必须证明四个 frontend 在对应的真实多盘数据模型上恢复、持久性、身份和错误语义正确，并证明 qtr managed NVMf-first attachment 可在重启和未知响应后收敛，iSCSI fallback 可互操作。

Tier 2 必须证明在线扩容与保护迁移可恢复、不会隐式改变策略，且多个 Volume/publication 的生命周期互不混淆。

任何 protection、transport 或 durability profile 在通过对应真实故障域与崩溃测试前都不得进入 Active 或作为可用保证对外发布。

Tier 3 必须逐项证明：

- 控制面重启和 Raft leader 切换不丢失已经确认的元数据。
- 同一 Volume 不存在两个可同时取得 data quorum 的 primary。
- 对已达到默认 3/2 current protection 的 Volume，客户端成功写入后任一单 Replica 故障不丢失该写入；override 只承诺其实际 threshold 可证明的保证。
- 旧 write epoch 在所有合格 Replica 上由持久 `max_accepted_epoch` 拒绝。
- Node 重启依靠持久身份、generation 和介质状态恢复，不依赖进程内存。
- internal Replica namespace 的创建、开放和撤销受 placement、Replica generation、lease 和 write epoch 约束。
- 控制面或数据面无法形成所需 quorum 时不静默降低一致性或确认阈值。
- storage primary 切换后旧 primary 受 Volume epoch fencing；host 转移时旧 controller/session 受独立 publication access-generation fencing，同一 Volume 才能安全 republish 到调用方指定 host。
- Raft authority、Replica quorum commit、storage failover、repair 和 republish 在进程崩溃、网络分区和旧节点恢复下持续保持单写者与已确认数据。
