# 计划 001：冻结 VolumeSnapshot 语义与协议

> **执行者说明**：本计划只修改架构文档，不实现代码。每一步都必须运行验证命令。
> 如果触发 STOP 条件，立即停止并报告，不要自行扩展语义。
>
> **漂移检查（首先运行）**：
> `git diff --stat 9d83bbe..HEAD -- docs/architecture/zh-CN` 和
> `git -C zettide diff --stat 6515277..HEAD -- docs/v3-multivolume-format.md`
> 如果相关文档已新增 Volume snapshot、clone、restore 或 consistency-group 设计，先逐项
> 对照本计划；语义冲突时停止。

## 状态

- **优先级**: P1
- **工作量**: M
- **风险**: LOW
- **依赖**: none
- **类别**: direction, docs
- **计划生成于**: root commit `9d83bbe`, `zettide` commit `6515277`, 2026-07-29

## 为什么重要

当前仓库中的 “snapshot” 只表示 Raft 状态机恢复镜像，Volume snapshot 尚无领域模型。
若直接添加 RPC，控制面 revision、数据面提交边界、littlefs root 和 v3 catalog root 很容易
被混为同一版本域。先冻结资源语义、持久证据和失败行为，可以防止后续代码提供一个只保存
元数据、却被误认为能恢复数据的伪快照能力。

## 当前状态

- `docs/architecture/zh-CN/03-domain-model.md:7-24`：控制面管理元数据，不承载数据块；
  `Volume`、`Replica` 和 reconciliation 仍是目标设计。
- `docs/architecture/zh-CN/03-domain-model.md:107-123`：ID、placement、quorum、epoch、
  generation、无副作用 apply 和 request ID 是必须保持的不变量。
- `docs/architecture/zh-CN/04-control-plane.md:65-81`：mutation 只有 apply 后才成功，且
  所有变更必须幂等。
- `docs/architecture/zh-CN/04-control-plane.md:119-130`：外部介质操作必须由 reconciler 执行，
  结果再通过 Raft 改变权威状态。
- `docs/architecture/zh-CN/07-consistency-and-fencing.md:100-122`：数据写成功依赖 prepare
  quorum 和在两个 Replica 上持久化的 commit certificate。
- `zettide/docs/v3-multivolume-format.md:163-191`：未来 catalog 必须 COW 写入、由 control
  authority 绑定 root digest，并禁止复用任一 recoverable root 引用的 extent。
- `services/controller/proto/zettide/controller/v1/controller.proto:89-93`：现有 `StateSnapshot` 仅含
  Pool 和 request records。

必须在新文档中固定以下定义：

```text
VolumeSnapshot = immutable block-level point-in-time image of one Volume,
bound to source volume generation, write epoch, committed sequence,
snapshot root digest, and a durable data-quorum certificate.
```

## 需要使用的命令

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Root drift | `git diff --stat 9d83bbe..HEAD -- docs/architecture/zh-CN` | 输出可人工对照；无未解释冲突 |
| Data doc drift | `git -C zettide diff --stat 6515277..HEAD -- docs/v3-multivolume-format.md` | 输出可人工对照；无未解释冲突 |
| Links | `grep -l "12-volume-snapshots.md" docs/architecture/zh-CN/README.md docs/architecture/zh-CN/source-map.md` | 恰好输出两个文件 |
| Terms | `for term in VolumeSnapshot committed_sequence snapshot_root_digest certificate_digest protection_set; do grep -q "$term" docs/architecture/zh-CN/12-volume-snapshots.md || exit 1; done` | exit 0 |
| Root diff | `git diff --check -- docs/architecture/zh-CN` | exit 0, no whitespace errors |
| Submodule diff | `git -C zettide diff --check -- docs/v3-multivolume-format.md` | exit 0, no whitespace errors |

## 临时目录约定

- 临时文件只能放在 `$HOME/tmp`。
- 不要在仓库内生成临时设计草稿。

## 范围

**范围内**：

- `docs/architecture/zh-CN/12-volume-snapshots.md`（新建）
- `docs/architecture/zh-CN/README.md`
- `docs/architecture/zh-CN/glossary.md`
- `docs/architecture/zh-CN/03-domain-model.md`
- `docs/architecture/zh-CN/04-control-plane.md`
- `docs/architecture/zh-CN/06-io-and-control-flows.md`
- `docs/architecture/zh-CN/07-consistency-and-fencing.md`
- `docs/architecture/zh-CN/08-failure-and-recovery.md`
- `docs/architecture/zh-CN/11-evolution-roadmap.md`
- `docs/architecture/zh-CN/source-map.md`
- `zettide/docs/v3-multivolume-format.md`

**范围外**：

- 所有 `.zig`、`.proto` 和 build 文件。
- application-consistent snapshot、guest agent、filesystem freeze。
- multi-Volume consistency group。
- 原地 restore、备份导出、跨集群复制。

## Git 工作流

- Branch: `advisor/001-volume-snapshot-contract`
- 使用仓库现有英文 commit 风格，例如 `docs: define volume snapshot semantics`。
- 不要 push 或创建 PR，除非 operator 明确要求。

## 步骤

### 步骤 1：定义资源与版本域

新建 `docs/architecture/zh-CN/12-volume-snapshots.md`，明确区分：

| Domain | Value | Meaning |
|--------|-------|---------|
| Control metadata | `created_revision`, `ready_revision`, `resource_version` | Raft apply 顺序 |
| Source write authority | `source_write_epoch` | 捕获时的 fencing epoch |
| Source data boundary | `source_committed_sequence` | 快照包含的连续 committed prefix |
| Data identity | `snapshot_root_digest` | 不可变 snapshot descriptor/root |
| Protection evidence | `certificate_digest` | 至少两个当前 generation Replica 的持久证明 |
| Local catalog | `catalog_generation`, `catalog_root_digest` | 数据节点本地 publication，不等于 Raft revision |

定义首版 snapshot 是单 Volume、只读、不可变、crash-consistent。并明确 concurrent write 按
primary sequence barrier 排序：barrier 前已 committed 的写必须包含，barrier 后的写必须排除，
结果未知的 unresolved sequence 必须先恢复为 committed 或 aborted，不能猜测。

单个 Replica 不保证拥有完整 committed prefix。规范必须要求先合并 recovery quorum 的
certified histories，将 boundary 以内缺失的 payload/certificate write-back 到 protection set
中的至少两个 Replica，逐 sequence/range 校验连续性和 checksum，再创建 SnapshotRoot。

**验证**：Terms 命令命中所有核心术语。

### 步骤 2：定义生命周期和 API 契约

写入以下状态与对外语义：

```text
CREATING -> READY | FAILED | DELETING
READY -> DELETING
FAILED -> DELETING
DELETING -> TOMBSTONED
```

固定以下行为：

- Create 在 `CREATING` intent 经 Raft apply 后返回，不等待数据复制。
- Get/List 走 ReadIndex，并返回当前 lifecycle、availability、operation phase 和 revision。
- 数据面 certificate 持久化定义 capture point；只有 certificate 被验证且
  `CompleteVolumeSnapshot` 经 Raft apply 后才对外进入 `READY`。
- Delete 先进入 `DELETING`；逻辑不可达与物理空间回收是两个完成点。
- 相同 request ID 和相同语义必须返回原结果；不同语义返回 conflict。
- `READY` snapshot 可以独立于源 Volume 生存；`CREATING` snapshot 阻止源 Volume 删除，
  或必须先被显式取消并安全清理。
- `READY` snapshot 固化自己的 protection set、Replica generations 和 read-only access
  identity。源 Volume placement 删除后不能作为 snapshot read/delete 的成员来源。
- protection member 是独立的 `SnapshotReplica`/allocation identity。Capture 时从 source
  Replica 的数据形成 snapshot-owned persistent root/pins；source Volume 删除只释放其 owner
  reference，不删除 snapshot owner。Repair 通过 Raft 预留新的 Node/Member allocation，完成
  materialization 和 attestation 后才切换 protection revision。
- 合法空 Volume 使用非零 epoch 和 `committed_sequence = 0`，不得因 sequence 为零拒绝。

**验证**：`grep -n "CREATING.*READY\|DELETING.*TOMBSTONED" docs/architecture/zh-CN/12-volume-snapshots.md` 至少命中状态定义。

### 步骤 3：定义 capture barrier 与 DataService 证据

把以下顺序写成规范性流程：验证 lease/epoch/generation；停止接收新写；drain；解决唯一
unresolved sequence；固定 committed boundary；合并 quorum certified histories；将完整前缀
write-back 并校验到至少两个 protection Replica；持久化 snapshot root 和 extent pins；在
两个 Replica 上持久化相同 certificate；恢复新写；最后提交 Raft `READY`。

明确控制面只接受由 reconciler 从 DataService 返回并验证的证明，客户端不能在 public RPC
中提供 root digest、sequence 或 certificate。

**验证**：`grep -n "drain\|certificate\|客户端不能" docs/architecture/zh-CN/12-volume-snapshots.md` 三类约束均命中。

### 步骤 4：定义 COW、删除和恢复约束

扩展 `zettide/docs/v3-multivolume-format.md`，冻结可直接实现的 versioned layout，而不是只写
字段方向。必须给出 magic、encoded size、字段 offset/size、reserved-zero 区域、CRC32C 范围、
BLAKE3 canonical digest domain、SnapshotRoot page reference、snapshot index root、extent-owner
entry、retired extent entry、certificate/attestation encoding，以及 catalog root v1 的读取和
升级策略。未完成完整表格时计划 003 保持 BLOCKED。

- Snapshot descriptor 必须绑定 source Volume ID、logical size、extent-map root、header/root、
  epoch、sequence 和 digest。
- Active Volume 后续覆盖一个被 snapshot 引用的 extent 时必须 COW。
- Snapshot 引用关系和 retired/quarantine 状态必须持久化，并参与 reopen/authority selection。
- 任一 recoverable root 仍引用 extent 时禁止复用。
- 删除先移除可达性和持久化 tombstone，再异步回收；未知 publication 结果 freeze mutation。

定义只读数据路径：snapshot session/namespace 绑定 snapshot ID、root digest、protection revision
和 Replica generation；只能从已物化并校验到 certified boundary 的 Replica 读取。Delete 必须
先拒绝新 session，再 revoke/disconnect/drain 所有旧 reader 和在途 I/O。

定义 safe reclaim frontier：最后引用删除后提交 removal generation `G_remove`；修复当前
protection set 每个合格 Replica 的 A/B roots，使旧 root 不再可恢复；在更高 generation
`G_safe` 上以 quorum certificate 持久化 reclaim barrier，绑定 retired extent set digest、
最小 Replica generations 和 `G_remove`。只有本地已 reopen 到 `G_safe`、两份 root slot 都不再
引用 extent、且旧 generation 被 fencing 后，才可把 extent 加回 free allocator。

文档不得选用当前并不存在的 littlefs snapshot API，也不得把 v3 journal checkpoint 描述为
Volume snapshot。

**验证**：`grep -n "copy-on-write\|recoverable root\|tombstone" zettide/docs/v3-multivolume-format.md` 均有规范性命中。

### 步骤 5：更新路线图和源码映射

在阶段 8 durable repair/replacement 之后增加独立 Volume snapshot 阶段，并明确复用阶段 4–8
的 placement、allocation、repair、generation 和 fencing。`source-map.md` 必须标注该能力仍是
目标状态，不能因为存在 codec 就标为当前。

**验证**：Links 和 Diff 命令全部通过。

## 测试计划

本计划是文档变更，无运行时测试。使用术语 grep、链接检查和 `git diff --check` 作为机器化
门禁。人工 review 必须核对新文档没有弱化 `03-domain-model.md:107-123` 与
`07-consistency-and-fencing.md:100-122` 的既有不变量。

## 完成标准

- [ ] 新文档定义资源、状态机、版本域、capture barrier、失败行为与删除边界。
- [ ] 首版明确只承诺 crash consistency。
- [ ] `StateSnapshot` 与 `VolumeSnapshot` 没有术语混用。
- [ ] `README.md` 和 `source-map.md` 可导航到新文档。
- [ ] 路线图显式包含 snapshot，并列出阶段 4–8 前置依赖。
- [ ] Root diff 和 Submodule diff 均 exits 0。
- [ ] 没有修改范围外文件。

## STOP 条件

- 当前分支已有另一份 Volume snapshot ADR，且它选择 application consistency、完整停写复制
  或原地 restore 作为首版。
- `Volume`/Replica protocol 的既定语义已从 3 replicas、2/3 quorum 改为其他模型。
- 设计需要修改当前 v3 稳定 codec，却没有格式版本和旧盘读取策略。
- 文档无法说明一个 snapshot 在源 Volume 删除后由谁拥有 extent 引用。
- 文档无法给出 SnapshotRoot/catalog v2 的精确字节布局和 v1 读取策略。
- 文档无法证明轮换 write quorum 形成的完整 committed prefix 已 materialize 到 snapshot
  protection set。

## 维护说明

未来增加 clone、restore 或 consistency group 时必须引用本规范的版本域和 certificate 语义，
不能另建相互不兼容的“时间点”定义。Reviewer 应重点检查是否把 Raft revision 当成数据提交
位置，或把单 Replica root 当成权威快照。
