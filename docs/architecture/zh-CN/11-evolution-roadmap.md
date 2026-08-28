# 演进路线图

> 状态：实施顺序，不代表发布日期或生产承诺

## 已有基础

- FUSE + regular Blob file 与多成员 raw Blob Pool。
- NFSv3 backend/`FSAL_ZETTIDE` 与单成员真实 RPC gate。
- Catalog、extent mapping、writable backend、endpoint registry/daemon。
- 标准 Catalog NVMf TCP/RDMA export 与 focused/physical-device test harness。
- vhost-user-blk 与 NVMe-oF initiator library paths。
- `zettide-control` metadata、heartbeat、Raft/WAL/snapshot/ReadIndex。
- qtr 手动外部 iSCSI discovery/login/logout/device discovery。

这些能力仍只使 Tier 1 状态为“部分”。

## Milestone 1：冻结 Tier 1 资源契约

- 固定 Catalog Volume 与 BlobFilesystem data mode 边界。
- 固定 protocol-neutral Publication/Export、stable identity、access generation 和 operation ID。
- 固定同机与独立单节点 deployment contract。
- 建立真实独立物理盘识别和 destructive-test safety gate。

完成标准：资源 identity、data mode、operation ID 和 generation 在 schema、文档与测试中一致；未通过对应硬件和故障测试的 profile 不得标记 Active。

## Milestone 2：完成四前端

- 标准 NVMf：完善 endpoint lifecycle、consumer generation、identity、restart/flush/discard/resize gate。
- iSCSI：实现 SPDK target/LUN、stable SCSI identity、ACL/credential 与 recovery。
- NFS：让 FSAL 组装多成员 Blob Pool，补齐声明的 NFSv3 profile。
- FUSE：保持多成员路径并完成真实多盘 durability/recovery gate。

完成标准：四个 frontend 都在对应 data model 的真实多物理盘 Pool 上通过准入；单文件/单盘 gate 仅作为补充。

## Milestone 3：qtr Tier 1 Managed Backend

- qtr 持久化 Volume/publication/attachment identity，不持久化瞬时 device path。
- 实现 NVMf controller connect、namespace identity verification、libvirt attach 与 restart reconciliation。
- 实现显式 policy/capability 驱动的 iSCSI fallback。
- 验证 unknown response、duplicate request、controller/session loss、device renumbering 与 interrupted detach。
- 覆盖同机和独立 storage node E2E。

完成标准：NVMf-first create/publish/attach/restart/detach 自动收敛；iSCSI fallback 受管可用；无需手工 `nvme connect`、`iscsiadm` 或填写 `/dev/...`。这是 Tier 1 gate，不放到 Tier 2。

## Milestone 4：Tier 1 完整准入

- 将 qtr 与四前端真实多盘 gate 汇总为一个 Tier 1 matrix。
- 覆盖进程/host restart、路径丢失、Member fault、身份错配和权限失败。
- 分别验证同机与独立单节点拓扑。

完成标准：Tier 1 matrix 的所有必需项均通过，且同机与独立单节点拓扑的结果可复现。完成后仍只声明单 storage node 能力，不声明 storage HA 或生产可用。

## Milestone 5：Tier 2 动态 Pool 与治理

- Member joining/active/draining 与 online capacity publication。
- Pool default/per-Volume override、desired/current/migration phase。
- 可恢复 copy/verify/publish migration 与安全 allocation release。
- multi-Volume quota、observability、upgrade、publication/attachment governance。

完成标准：加盘可以只扩容或按显式策略迁移选定 Volume；已有保护策略不被隐式改变，任一 copy/verify/publish 崩溃点均可安全恢复，旧 allocation 只在新保护达成后释放。

## Milestone 6：PVE 与其他平台

- 实现 PVE storage plugin，将 stable Volume identity 映射到 standard NVMf-first/iSCSI-fallback lifecycle。
- 支持 platform-native allocation、attach/detach、rescan、resize、migration preparation 与 error mapping。
- 复用 Zettide publication authority，不发明 PVE-specific data semantics。

PVE 与其他虚拟化平台是一等后续集成目标，优先于 CSI，但不阻塞 Tier 1。

完成标准：PVE 在同一稳定 Volume identity 上完成 allocate/activate/restart/deactivate/free、resize 和保持该 Volume 可达的 migration preparation；路径变化或 provider timeout 不产生重复 Volume 或双重 exclusive publication。

## Milestone 7：CSI 次级集成

- 映射 CSI Controller lifecycle 到 Volume/Publication/Export。
- 映射 CSI Node lifecycle 到 NVMf/iSCSI session/device 或 NFS/FUSE mount。
- 实现 service account、Node identity、secret、idempotency 与 topology mapping。

CSI 不阻塞 Tier 1/2，也不新增数据 plane。

完成标准：CSI 只广告并通过已实现的 access mode/capability，Controller/Node 重试保持幂等，错误 Node、错误 identity、未授权 secret 和不支持的共享写请求均被拒绝。

## Milestone 8：Tier 3 Placement 与 Allocation

- DataService 注册本地 topology、capacity、authority 和 Replica observation。
- 实现 ReplicaPlacement、ReplicaAllocation 和 VolumeAttachment mutation、extent allocator 与 reconciliation。
- 将 Pool default/per-Volume protection 扩展到跨 Node 故障域，并按 current protection 报告实际故障保证。
- 实现 Replica generation、幂等 EnsureReplica、删除 quarantine、allocation release 和 relocation。

当前 control metadata 只提交固定 3/2/1 `PROVISIONING` intent；schema 存在不能作为 placement/allocation 已接线的证据。

完成标准：placement 与 allocation 是可独立恢复、审计和重试的资源；重启、重复请求和部分分配不会创建重复 Replica、提前释放 allocation 或把 desired protection 报成 current protection。

## Milestone 9：Tier 3 Replica 协议

- 创建独立 internal NVMf Replica subsystem、namespace、listener 和 initiator session。
- 定义 vendor-specific `PREPARE`/`COMMIT` commands 与 target-owned metadata。
- 实现 per-Volume journal、sequence、checksum、Replica position 和两阶段 commit certificate。
- 验证 TCP/RDMA、qpair 中断、每个崩溃窗口和默认 2/3 持久成功语义。

完成标准：对已经达到默认 3/2 current protection 的 Volume，任一单 Replica 故障后，所有已确认写入仍可从 recovery quorum 证明并恢复；较低 protection override 只获得其 threshold 可证明的保证。标准 host-facing NVMf export 不能作为该 milestone 已完成的证据。

## Milestone 10：Tier 3 Fencing、Failover 与 Republish

- 实现 lease grant/renew/revoke、Volume write epoch 和 Replica `max_accepted_epoch`。
- 固定 quiesce、disconnect、drain、flush、persist epoch 和 reopen barrier。
- 合并 certified histories，恢复连续 committed prefix 后才激活新 primary。
- 将 host-facing publication authority 和独立 access generation 纳入 Raft；DataService 持久化最高 installed generation。
- 可达旧 target 先 quiesce/drain session 并撤销 ACL/credential；失联 target 依靠 primary lease 到期和 Replica epoch fencing 阻止旧路径提交。
- 在新 target 激活 publication generation；adapter 在调用方指定 host 上以同一 Volume/consumer identity reconcile session 与 attachment。

完成标准：pause old primary、promote、resume old primary、storage node loss 和跨 host republish E2E 同时证明不会出现两个可写 primary 或两个有效 exclusive publication generation。VM host 选择和自动 workload restart 不属于该标准。

## Milestone 11：Repair 与 Production Admission

- 实现增量/全量 rebuild、scrub、限速、进度上报和 Replica relocation。
- 增加 services/control/DataService 双向认证、per-host NVMf/iSCSI/NFS authorization 和 adapter/CSI identity binding。
- 建立 credential/certificate rotation、滚动升级、回滚、格式兼容和灾难恢复流程。
- 通过断电、网络分区、介质损坏、旧 host 恢复、长稳和资源耗尽测试。

完成标准：repair 中断可恢复且不污染 current protection；生产 profile 在真实故障域完成 power-cut/partition/corruption/stale-host/long-soak/resource-exhaustion matrix，并具有可演练的升级、回滚、凭据轮换和灾难恢复程序。

## Shared-file 支线：TxFS qcow2

该支线不替代 protocol-neutral block publication route，按以下依赖顺序推进：

1. 完成 SCSI-backed immutable object store、统一 fault model 和 mount recovery。
2. 完成 backend-neutral filesystem interface 与 TxFS POSIX backend。
3. 实现受管 FUSE lifecycle，验证多 host shared mount。
4. 通过 `qemu-img`/QEMU cache、locking、sparse 和 durability profile。
5. qtr 持久化 TxFS volume/image identity、ownership intent 和 libvirt reconciliation。
6. 接入 power fence 或 LUN revoke，验证 fenced takeover 和旧 host 恢复。

完成标准：两台 host 可在同一 TxFS LUN 上并发运行不同 qcow2；同一 qcow2 的第二个 writable start 被拒绝；clean transfer 和 externally fenced takeover 均不产生旧 epoch 写入或已确认写丢失。详细契约见 [TxFS 共享 qcow2 接入](12-txfs-shared-qcow2.md)。

## 路线图约束

- 不用 format/schema/library test 代替产品 E2E。
- 不用单文件、单盘、loop 或 synthetic member 代替 Tier 1 真实多盘 gate。
- 不把 Member count 当成 Volume current protection。
- 不把标准 host-facing NVMf 与 internal Replica NVMf 混写。
- 不把 CSI、PVE 或 TxFS 定义为新数据一致性模型。
- 不在 commit evidence/fencing 前声明 storage failover。
- 不把 republish 描述为 VM 调度或自动重启。
- 不在认证授权完成前放宽可信隔离网络。
