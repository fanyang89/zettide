# 计划 004：完成快照删除、空间回收与故障验证

> **执行者说明**：本计划在 create/read 已端到端可用后增加 Delete 和 GC。逻辑删除成功
> 不能被描述为空间已经立即释放。
>
> **漂移检查（首先运行）**：执行计划 003 的两个子仓库 drift 命令，并确认 SnapshotRoot、
> COW pinning、certificate reopen tests 已存在且通过。

## 状态

- **优先级**: P1
- **工作量**: L
- **风险**: HIGH
- **依赖**: `docs/plans/003-connect-crash-consistent-snapshot-data-plane.md`
- **类别**: direction, tests
- **Status**: BLOCKED（等待计划 003 完成并按实际文件刷新）
- **计划生成于**: `zettide` commit `6515277`, `zettide-control` commit `c25ed1d`, 2026-07-29

## 为什么重要

快照若不能删除会永久泄漏容量；若删除过早复用 extent，则崩溃恢复或旧 operation 可能重新
暴露已被覆盖的数据。安全删除必须先从 Raft 和数据节点撤销可达性、持久化 tombstone，确认
所有 recoverable roots 都不再引用数据，最后才进入 quarantine/reclaim。该计划同时补齐
最危险的断电、leader change 和 generation 重放测试。

## 当前状态

- `docs/architecture/zh-CN/06-io-and-control-flows.md:89-91`：Replica 删除必须先撤销
  namespace/session，再 tombstone、quarantine，最后才能重分配 extent。
- `zettide/docs/v3-multivolume-format.md:163-173`：任一 recoverable root 引用的 extent 不得
  复用，unknown outcome 必须 freeze。
- `services/controller/src/state_machine.zig:499-612`：当前 request restore 校验假定 CreatePool
  对应 live Pool；删除资源后必须改为 live-or-tombstone 证明。
- 计划 003 应已提供 snapshot ID/root digest/certificate 和持久 extent ownership。

## 需要使用的命令

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Controller tests | `zig build test --summary all` in `services/controller/` | all pass |
| Unit tests | `zig build test-unit --summary all` in `zettide/` | all pass |
| Image tests | `zig build test-image --summary all` in `zettide/` | all pass |
| Fault tests | `zig build test-fault --summary all` in `zettide/` | all pass |
| Linux block | `zig build test-linux-block -Dblock-tests=required --summary all` in `zettide/` | all pass on configured host |
| CI gate | `zig build ci --summary all` in `zettide/` | all pass |
| Controller diff | `git -C zettide-control diff --check -- proto src README.md` | exit 0 |
| Data diff | `git -C zettide diff --check -- src docs build.zig test` | exit 0 |

若执行环境没有配置 privileged Linux block test，必须报告 BLOCKED，不得把该项静默改为
optional 后宣称完成。

## 临时目录约定

- 故障镜像、block-device scratch 和 disposable worktree 只能放在 `$HOME/tmp`。
- 测试结束后由 harness 清理；不要提交镜像。

## 范围

**范围内**：

- 计划 002/003 新增的 VolumeSnapshot proto、state machine、service、reconciler 和 DataService 文件
- `services/controller/src/integration_test.zig`
- `services/zettide/v3/pool_catalog.zig`
- `services/zettide/v3/snapshot_root.zig`
- `services/zettide/v3/volume_snapshot.zig`
- `services/zettide/v3/pool_replicated_journal.zig`
- `zettide/tests/fault.zig`
- `zettide/tests/image.zig`
- `zettide/tests/linux-block.sh`
- `zettide/build.zig`
- 与 snapshot 对应的新测试文件
- `docs/architecture/zh-CN/12-volume-snapshots.md`

**范围外**：

- clone、restore、backup/export、application consistency。
- Snapshot name update 或 mutable metadata。
- 自动缩短 quarantine 以改善测试速度。
- 删除仍被 clone 或其他 recoverable root 引用的数据。

## Git 工作流

- Branch: `advisor/004-snapshot-delete-gc-faults`
- 按 control tombstone、DataService delete、GC、fault matrix 分 commit。
- Commit 风格示例：`test: cover Pool WAL recovery`。
- 不要 push 或创建 PR，除非 operator 明确要求。

## 步骤

### 步骤 1：增加异步 Delete API 与 tombstone

增加 `DeleteVolumeSnapshot(request_id, snapshot_id, expected_resource_version)`。Apply 只把 live
resource 转为 `DELETING + UNAVAILABLE + RECLAIMING` 并生成唯一 delete operation ID；重复 Delete
返回同一结果。允许从 CREATING、READY、FAILED 进入 DELETING，禁止从 tombstoned ID 重新创建。

Delete intent apply 必须先在 tombstone map 中插入 `RESERVED` placeholder，原子占用一条
tombstone 容量和后续 finalize 所需内存。若 `live_tombstones + reserved_tombstones` 已达到
`max_volume_snapshot_tombstones`，Delete 返回 `RESOURCE_EXHAUSTED`，资源保持原状态，reconciler
不得启动任何数据面删除。

同一 apply 还必须把 snapshot 的 active、initial reserved、materializing、repair reserved 和
retiring allocations 全部冻结到 immutable `delete_allocation_set`，并把每个 in-flight operation
generation 递增到 cancelled/fenced 状态。旧 capture/repair completion 从此只能返回 stale；不能
再激活 owner 或改变 protection set。该集合是 deletion proof 的精确全集，不能只取最后
committed protection revision。

新增 `FinalizeVolumeSnapshotDelete` internal command，只有 current delete operation、正确 resource
version 和有效 DataService deletion proof 才能把 `RESERVED` placeholder 原地转成 finalized
tombstone 并移除 live resource。Finalize 不再分配 tombstone 容量，因此不能因 tombstone limit
失败。List 排除 tombstone；Get 在 finalize 后返回 NOT_FOUND。

Request restore 必须验证 Create/Delete response 引用 live resource 或匹配 tombstone，不能因 live
map 已删除而拒绝合法 state snapshot，也不能放弃现有 corruption checks。

首版不淘汰 snapshot tombstone，也不重用 snapshot ID。设置明确的
`max_volume_snapshot_tombstones`；达到上限后新的 Delete intent 返回 `RESOURCE_EXHAUSTED`，
而不是删除旧 tombstone，已预留的 finalize 必须继续成功。Request history 仍按当前 bounded、无 GC 语义；
未来只有在 request 与 tombstone 能原子联动淘汰后才单独设计 GC。

**验证**：`zig build test --summary all` exit 0；覆盖 tombstone-full Delete 不改变 live resource、
reserved placeholder 跨 Raft snapshot/restart、数据删除后 finalize 在容量已满时仍成功，以及
create -> ready -> delete -> restore 后旧 request replay。

### 步骤 2：实现幂等 DataService 删除

增加 `EnsureVolumeSnapshotDeleted`，按 snapshot/delete operation ID 幂等执行：

1. 阻止新的 snapshot reader/namespace/session。
2. revoke 所有旧 read-only session，断开 namespace/controller，并 drain 已接收的读 I/O。
3. 对 `delete_allocation_set` 中每个 RESERVED/MATERIALIZING/RETIRING operation 查询持久结果；
   已产生 root/pins 的必须纳入删除，未 materialize 的 reservation 也要写 owner tombstone。
4. 在 snapshot 自己的每个 active、reserved、materializing 和 retiring
   SnapshotReplicaAllocation catalog 中持久化 tombstone。
5. 发布不再包含该 snapshot root 的新 authority-selected catalog root。
6. 返回绑定 protection revision、Replica generation 和 drained session frontier 的 attestation。

Control 只在 deletion attestations 的 allocation ID 集合与 Raft-frozen `delete_allocation_set`
完全相等、所有可达 root/pins 已撤销且旧 readers 已 drain 后 finalize。不能查询可能已经删除的
source placement。失联 Replica 上的旧 root 必须由
snapshot protection generation、epoch 和 quarantine 防止未来重新变为当前 authority。

**验证**：删除 response loss、DataService restart、controller leader change 和 stale old Replica
rejoin 都不能让 tombstoned snapshot 重新可见。

### 步骤 3：实现延迟 extent reclaim

GC 只能回收同时满足以下条件的 extent：

```text
not referenced by active catalog root
not referenced by any live snapshot root
not referenced by either recoverable A/B root
snapshot tombstone committed and observed locally
retirement generation older than the safe authority frontier
no unknown control transaction
```

`safe authority frontier` 的算法固定为：

1. 最后引用删除后提交 removal generation `G_remove`，其 root 和 certificate 绑定 retired
   extent set digest。
2. 修复 snapshot protection set 中每个仍合格 Replica 的 A/B root slots，使任一可选 root 都
   不再引用 retired extents；失联旧 Replica 必须先移出保护集合并推进 generation/fencing。
3. 在 `G_safe > G_remove` 提交 reclaim-barrier certificate，绑定 `G_remove`、retired set digest、
   protection revision 和每个参与 Replica generation。
4. 每个执行 free 的 Replica 必须已从磁盘 reopen 到 `G_safe`，验证本地 A/B roots 和所有
   recoverable roots 均无引用，并持久化 reclaim barrier。
5. 满足以上条件后，下一次 COW catalog publication 才能把 extent 加回 free allocator。

Out-of-space 时也不得跳过任何一步。单纯等待 generation 数量或 wall-clock grace period 不构成
safe frontier。

**验证**：在 tombstone、root publication、quarantine 和 free-list publication 每个阶段断电，
重开后 extent 要么仍被安全保留，要么已安全 free，绝不同时属于旧 snapshot 与新 owner。

### 步骤 4：定义源 Volume 删除交互

固定并实现：

- 存在 CREATING snapshot 时，source Volume delete 返回 FAILED_PRECONDITION，除非调用方先删除
  snapshot 并等待 tombstone。
- READY snapshot 已拥有独立持久 pins；source Volume 可以删除，snapshot 保持可读。
- READY snapshot 的 Raft restore 通过 frozen source identity/source tombstone 和 snapshot 自己的
  protection set 验证，不要求 live source Volume 或 source placement 仍存在。
- Source Volume 删除只撤销 source allocation owner；SnapshotReplicaAllocation owner 保留。
  后续 snapshot repair、read 和 delete 都从 snapshot protection set 选择 Node/Member。
- source Volume 删除不得回收 READY snapshot 仍引用的 extent。
- snapshot delete 与 source Volume delete 并发时按 resource ID 固定锁序和 expected revision
  串行，不得死锁或双重 free。

**验证**：覆盖 CREATING blocker、READY survivor、concurrent delete 和 restart 四类集成测试。

### 步骤 5：完成故障矩阵与数据校验

Fault suite 必须遍历：

- capture 的 data/page/root/prepare/certificate/control READY 前后。
- delete 的 revoke/tombstone/root/retire/free/finalize 前后。
- primary crash、controller leader stepdown、单 Replica loss、两 Replica loss。
- stale epoch writer、旧 Replica generation rejoin、response loss、request retry。
- active writes 跨 snapshot barrier、snapshot 后 overwrite、源 Volume 删除。
- snapshot reader 正在进行 I/O 时并发 Delete，证明先 drain 后 reclaim。
- Delete 分别并发于 initial reservation、partial capture materialization、repair reservation、
  replacement materialization、protection update 和 old allocation retirement。
- write 1 使用 A+B、write 2 使用 B+C 的轮换 quorum，证明 capture 前完整 prefix write-back。
- journal rollover 与 snapshot roots 共存。

每次恢复都校验 active Volume bytes、snapshot bytes、committed boundary、catalog ownership 和
free-list 无重叠。不能只检查 API 状态。

**验证**：本计划“需要使用的命令”全部通过。

## 测试计划

- Control：Delete 状态转换、request replay、tombstone restore、pagination 排除、resource limits。
- DataService：idempotent delete、partial Replica completion、stale operation、old generation rejoin。
- Storage：COW immutability、reference ownership、quarantine、safe frontier、out-of-space。
- End-to-end：create READY、overwrite、source delete、snapshot verify、snapshot delete、reclaim、
  new Volume reuse 后旧 snapshot 永不复活。
- Power-cut：每个 publication sync point 前后。

## 完成标准

- [ ] Delete 是异步、幂等且 revision-conditional。
- [ ] tombstone 跨 Raft snapshot/WAL 和数据节点 restart 持久。
- [ ] tombstone 不淘汰、不复用 ID，容量耗尽 fail closed。
- [ ] Delete intent 原子预留 tombstone；一旦数据面删除开始，Finalize 不会因容量失败。
- [ ] Delete proof 覆盖 active/reserved/materializing/retiring 全部 allocations，stale repair/capture
  completion 不能在 Delete intent 后激活任何 owner。
- [ ] READY snapshot 可独立于 source Volume 生存。
- [ ] CREATING snapshot 与 source Volume delete 交互明确且有测试。
- [ ] extent 只有经过 tombstone、authority publication、quarantine 和 safe frontier 后才复用。
- [ ] stale Replica/operation/epoch 无法复活或覆盖 snapshot 数据。
- [ ] 所有 control、unit、image、fault、Linux block 和 CI gates 通过。
- [ ] 没有修改范围外文件。

## STOP 条件

- 计划 003 的 snapshot root/certificate/COW tests 不稳定或未完成。
- 当前计划状态仍为 BLOCKED，或尚未按计划 003 的实际文件刷新范围。
- 无法枚举所有 recoverable roots，因而无法证明 extent 已无引用。
- 删除需要立即复用 extent 才能满足 API 契约。
- tombstone 无法跨 controller/data-node restart 持久。
- stale Replica 可以在没有更高 generation/epoch fencing 的情况下重新加入 authority。
- privileged block test 环境不可用且 operator 不接受计划保持 BLOCKED。

## 维护说明

未来 clone 会增加新的 root owner；GC 的“无引用”判定必须包含 clone/child Volume，不能只看
snapshot 表。Reviewer 应重点检查 delete API success 的措辞没有暗示空间已释放，以及每一个
free-list insertion 都能追溯到 durable tombstone、safe authority frontier 和 reopen proof。
