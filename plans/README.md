# 实施计划

由 improve skill 于 2026-07-29 生成。计划基于根仓库 commit `9d83bbe`、
`zettide-control` commit `c25ed1d` 和 `zettide` commit `6515277`。计划 002-004 依赖尚不存在的 Volume、Replica protocol、
reconciler 和 fencing baseline，因此当前状态为 `BLOCKED`；前置能力落地后必须按当时的
实际文件重新校准范围和验证命令，不能直接照搬未来路径。执行前必须做各计划中的 commit、
工作树 checksum 和摘录三重漂移检查；不要覆盖或回退其他并行修改。

## 设计结论

- 面向用户的资源命名为 `VolumeSnapshot`，与 Raft 的 `StateSnapshot` 严格区分。
- 首版只承诺块级 crash consistency，不承诺 filesystem/application consistency。
- 创建和删除是异步过程；管理 RPC 提交 Raft intent 后返回资源，调用方通过 Get/List
  观察最终状态。
- 快照时间点由数据面的 `(write_epoch, committed_sequence)`、不可变 root digest 和
  quorum certificate 定义。Raft revision 只标识元数据版本，不能替代数据提交边界。
- 快照必须在至少两个当前 generation Replica 上持久化相同 root 和 certificate 后才能
  进入 `READY`。
- Capture point 是数据面 certificate 在 quorum 上持久化的时刻；对外 `READY` 的线性化点是
  `CompleteVolumeSnapshot` 经 Raft apply 的时刻。两者必须分别记录。
- 首版使用 extent-map COW 和 recoverable-root pinning。没有持久引用关系与延迟回收前，
  不允许把普通可变 extent 直接共享给快照。
- `READY` snapshot 拥有独立 protection set，并通过只读 snapshot session/namespace 访问；
  不能依赖可能已删除的 source Volume placement。
- `RestoreSnapshot`、应用 quiesce、跨 Volume consistency group 和增量导出不在首版范围。
  后续恢复优先设计为“从快照创建新 Volume”，不把旧 lease/epoch 恢复到源 Volume。

## 执行顺序与状态

| Plan | 标题 | 优先级 | 工作量 | 依赖 | Status |
|------|------|--------|--------|------|--------|
| 001 | 冻结 VolumeSnapshot 语义与协议 | P1 | M | — | TODO |
| 002 | 增加 VolumeSnapshot 控制面资源 | P1 | L | 001、Volume baseline | BLOCKED |
| 003 | 接通 crash-consistent 数据面快照 | P1 | L | 002、data-plane baseline | BLOCKED |
| 004 | 完成删除、回收与故障验证 | P1 | L | 003 | BLOCKED |

状态值：TODO | IN PROGRESS | DONE | BLOCKED（附一行原因） | REJECTED（附一行理由）

## 依赖说明

- 002 依赖既有路线图中的 Volume baseline：至少已有 durable `Volume`、`ReplicaPlacement`、
  `write_epoch`、revision 和基础 reconciler。当前仓库只有 Pool，未满足该条件。
- 003 依赖既有路线图阶段 5–8：Replica protocol、2/3 commit evidence、lease/epoch、fencing、
  durable allocation 和 repair/replacement。缺少任一项时都不能宣称快照具有
  crash-consistent 数据语义，也不能安全维护独立 snapshot protection set。
- 004 必须最后执行，因为删除与空间复用只有在 COW root、certificate 和重开恢复路径
  已稳定后才能安全验证。

## 首版状态机摘要

```text
CREATING -> READY
CREATING -> FAILED
CREATING -> DELETING
READY    -> DELETING
FAILED   -> DELETING
DELETING -> TOMBSTONED
```

数据面 quorum certificate 持久化定义 immutable capture point。对外 `READY` 的线性化点是
随后 `CompleteVolumeSnapshot` 的 Raft apply；`created_revision` 和 `ready_revision` 分别表示
intent 与 READY 结果进入 Raft 的位置。

## 已考虑并拒绝的方案

- 复用 `StateSnapshot`：它只保存控制面恢复状态，不含 Volume 数据或 commit evidence。
- 只执行 `Volume.sync()`：它只能刷写当前 backing，后续写仍会覆盖或回收历史数据。
- 只保存 littlefs root：当前 littlefs 没有 pin root 可达块的 API，旧块会被重定位或复用。
- 创建时完整停写并复制整个 Volume：容量越大停写时间越长，不满足可控延迟目标。
- 首版原地 restore：它会有意丢弃快照后的已确认写，且必须重做 generation、epoch、
  fencing 和 lease，风险明显高于从快照创建新 Volume。
- 在 Raft apply 中执行 flush/COW/复制：apply 必须确定、原子且无外部副作用，慢操作只能
  由 reconciler 和 DataService 执行。
