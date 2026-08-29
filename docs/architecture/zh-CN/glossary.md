# 术语表

## Tier 1 / Tier 2 / Tier 3

- Tier 1：单 Zettide node 接管多块独立物理盘，以 NVMf/iSCSI 服务 Catalog Volume，以 NFS/FUSE 服务 BlobFilesystem；qtr managed backend 是完成门槛。
- Tier 2：在 Tier 1 上增加动态 Pool、在线容量/保护迁移、multi-Volume 与 publication/attachment 治理。
- Tier 3：跨 data node Replica、fencing、failover、repair 和 republish。

## Pool 与 Member

Pool 是相同 data mode 下的容量和策略边界。Member 是具有稳定 identity、geometry、slot、control history 与介质故障边界的持久单元。设备路径不是 Member identity。只有落在不同独立物理盘上的 Member 才能计入 Tier 1 合格独立故障域；regular file、loop、partition、slice 或同一物理盘上的多个 Member 不能冒充该保证。

本地 v3 Pool 与 Tier 3 控制面 Pool 是不同层次对象；后者可聚合多个 Node 的资源。

## Catalog Volume

Catalog Pool 中具有稳定 Volume ID、固定逻辑 block address space 与 extent mappings 的资源。标准 NVMf 和 iSCSI 访问它。它不是 BlobFilesystem 中的文件。

当前控制面 Volume 是固定 3/2/1 的 durable `PROVISIONING` metadata intent，支持无依赖条件下的 tombstone Delete；尚未接通 placement、数据面或 frontend。

## BlobFilesystem

由 Blob stores 持久化 inode/blob/COW metadata 的 filesystem model，可位于 regular Blob file 或 Blob Pool。NFS 与 FUSE 访问它。TxFS 是独立 shared-file direction，不是 BlobFilesystem backend。

## Data Mode

Pool 的持久模型标记，当前架构区分 Catalog 与 Blob。Data mode 决定可用 frontend，禁止以错误模型打开或让 block/filesystem frontend 并发访问同一对象。

## Publication

Catalog Volume 对指定 consumer/host 的协议中立 block export authority，包含 stable publication ID、protocol、access mode、access generation 与 locator。标准 NVMf 是首选，iSCSI 是 fallback。

Exclusive Publication 的 access generation 单调增加。目标单节点阶段在本地持久化，Tier 3 由 Raft 保存 authority，各 DataService 持久化最高 installed generation。可达旧 target 必须通过 session/controller context、ACL/credential、quiesce、drain 和撤销隔离；失联旧 target 还依赖 primary lease 到期与 Replica epoch fencing。Publication generation 与 Volume write epoch 不能互相替代。

## Export 与 Mount

Export 是 BlobFilesystem 的 network-facing NFS authority；Mount 是 host 上的 FUSE/NFS access lifecycle。Export path 和 mount point 都不是 filesystem identity。

## Attachment

Volume、Publication、consumer、host 与 VM/libvirt disk 之间的持久 intent。它先于外部副作用写入，并通过 provider/host/platform observations reconciliation。

## Access Generation

Publication 的单调 consumer fencing 版本。NVMf controller 与 iSCSI session 都必须匹配当前 generation。它不等于 Tier 3 Volume write epoch。

## 标准 Host-facing NVMf

Catalog Volume 到 host 的标准 NVMe over Fabrics block publication，支持 TCP/RDMA。当前 endpoint daemon/export 有部分实现。NQN、NSID、controller 和 `/dev/nvme...` 是 locator/observation。

## Internal Replica NVMf

Tier 3 primary 到 Replica 的目标 vendor-specific transport，携带 Volume/Replica generation、write epoch、sequence 与 commit evidence。尚未实现，不能与标准 host-facing NVMf 混写。

## iSCSI

Catalog Volume 的 fallback/compatibility block protocol。Portal、IQN、LUN 和 session 是 locator/runtime state；stable serial/WWID 用于设备验证。Zettide 当前已有 SPDK target/export、endpoint lifecycle 和 focused fio profile，但没有 consumer-bound Publication generation 或 managed host attachment。

## NFS

BlobFilesystem 的 network filesystem frontend。当前有 NFSv3 backend/`FSAL_ZETTIDE`，但只打开单成员，尚未完成多物理盘 Tier 1 gate。

## FUSE

BlobFilesystem 的 local filesystem frontend。当前 foreground Linux path 可访问 regular Blob file 和多成员 Blob Pool。

## Node、Raft Node、Replica 与 Primary

Node 是运行 DataService/Volume Engine 的受管 data node，使用稳定 `node_id`。`raftz` node 是 Raft voter/participant，属于独立身份域；两者不能按地址、hostname 或数值 ID 隐式等同。

大写 Replica 是 Tier 3 Catalog Volume 的正式持久资源，绑定 Volume、稳定 Node、
本地介质和跨节点故障域。Tier 2 在同一 data node 上使用 local protection
copy，不因此创建控制面 Replica resource。Primary 是单个 Tier 3 Volume 的唯一
写协调者，不是 Raft leader，也不等于 host-facing publication target。

当前 `ReplicaEndpoint` 是本地 I/O vtable，不是 internal Replica protocol。

## Lease 与 Epoch

Lease 限制 primary 授权时间；Volume write epoch 单调隔离旧 primary。它们与 publication access generation、本地 Pool membership epoch、Raft term 都是不同版本域。

## Replica Generation

Replica 持久数据实例的代次，绑定 Volume、Node、介质、applied position 和最高接受 epoch。Replica 重建或替换后必须使用新 generation，防止旧 namespace、旧 allocation 或残留本地数据被误认为当前副本。

## Revision

控制面状态机的已提交版本，通常对应或派生自 apply 的 Raft log index。Revision 用于一致读取、expected-state mutation 和 reconciliation，不等于 Raft term、Volume epoch 或 generation。

## Quorum

完成某类决策所需的最小参与者集合。必须区分 Raft metadata quorum、本地 Pool control quorum 和 Tier 3 Volume data commit/recovery quorum；一个域的 quorum 不能代替另一个域的持久证据。

## Protection Policy

Volume 的 desired replica/read/write thresholds。Pool 可提供 default，Volume 可 override。Desired protection、current protection 和 migration phase 必须独立；Member 数量不证明 current protection。

## Authority / Desired State / Observed State / On-media Facts

Authority 是从持久控制记录和对应 quorum evidence 中选择出的可接受状态，不表示安全认证。Desired state 是权威控制状态中的目标，例如 placement、primary、epoch、publication 和管理状态。Observed state 是 leader/agent 从 heartbeat、session、路径和探测得到的易失运行事实，本身不授予写权限。On-media facts 是 Member/Replica 在重启后从持久 header、journal、generation、position 和 commit evidence 可证明的介质状态。

## Reconciliation

比较 desired、observed 与 on-media facts，执行带稳定 identity、revision 和 generation 的幂等动作，使系统收敛。“命令已发送”或“路径可达”不等于 desired state 已达成。

## Fencing

阻止旧 writer 继续写入。Host publication 使用 access generation；Tier 3 primary 使用 lease、write epoch 与 Replica persistent enforcement；TxFS image 使用独立 owner epoch 与 external hard fence。

## qtr / PVE / CSI

qtr 是 Tier 1 阻塞性一等外部 consumer；PVE/其他虚拟化平台是一等后续外部集成目标。本仓库不维护其实现状态。CSI 是次级、非阻塞 adapter，复用 NVMf/iSCSI 与 NFS/FUSE；当前仓库内只有静态 regular Blob file 的 FUSE CSI Node service 和独立 FUSE/NFS kind profiles。

## Republish

为同一 Volume/consumer 在调用方指定 host 激活更高 publication generation 并重建 attachment。Tier 3 storage primary 同时失效时还需独立 Volume epoch recovery。Republish 不等于 VM 调度或自动重启。

## RDMA 与 iWARP

InfiniBand、RoCE 与 iWARP 是 RDMA 环境；SPDK 使用统一 `RDMA` transport。iWARP 不是普通 TCP fallback。Tier 1 标准 NVMf TCP 与 Tier 3 internal RDMA decision 相互独立。
