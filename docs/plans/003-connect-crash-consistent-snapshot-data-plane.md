# 计划 003：接通 crash-consistent Volume 快照数据面

> **执行者说明**：本计划实现 DataService、reconciler 和持久 COW snapshot root。只有所有
> 数据证据门禁通过后，才能注册 public Create RPC 并将资源置为 READY。
>
> **漂移检查（首先运行）**：
> `git -C zettide diff --stat 6515277..HEAD -- src docs build.zig test` 和
> `git -C zettide-control diff --stat c25ed1d..HEAD -- proto src README.md`
> 执行前对照计划中记录的 checksum；任一不匹配都先刷新本计划，不要覆盖或回退其他修改。

## 状态

- **优先级**: P1
- **工作量**: L
- **风险**: HIGH
- **依赖**: `docs/plans/002-add-volume-snapshot-control-resource.md`、Replica protocol、2/3 commit、lease/epoch/fencing baseline
- **类别**: direction
- **Status**: BLOCKED（等待计划 001 的精确磁盘格式及阶段 5-8 baseline）
- **计划生成于**: `zettide` commit `6515277`, `zettide-control` commit `c25ed1d`, 2026-07-29

## 为什么重要

控制面中的 `CREATING` 记录本身不保存历史数据。真正的快照需要在一个已证明的 committed
prefix 上发布不可变 root，并保证后续写通过 COW 不修改该 root 可达的数据。该过程必须在
Replica quorum 上持久化证据，且 leader change、RPC timeout 和 response loss 后能用相同
operation ID 收敛到同一结果。

## 当前状态

- `services/zettide/volume.zig:776-783`：`Volume.sync()` 只 flush 当前 backing，不返回或 pin root。
- `services/zettide/v3/replica_endpoint.zig:11-17`：当前 endpoint 只有 read/write/sync，没有
  volume ID、epoch、sequence、snapshot 或 certificate。
- `services/zettide/v3/control_record.zig:62-89`：control record 能表达 generation、root digest 和
 两份 attestation，但当前未绑定 Volume snapshot。
- `services/zettide/v3/pool_replicated_journal.zig:72-150`：generation commit 已有 prepare/commit
  基础和 unknown-outcome freeze，但生产 Volume 未接线。
- `zettide/docs/v3-multivolume-format.md:70-121`：Volume descriptor 已有 extent-map root。
- `zettide/docs/v3-multivolume-format.md:163-191`：COW publication、root binding、pinning 和
  unknown-outcome freeze 是既定不变量。
- `docs/architecture/zh-CN/07-consistency-and-fencing.md:100-122`：Volume write 的权威边界来自
  `(epoch, sequence)` 与 2/3 certificate，而非单副本内容。

## DataService 契约

新增内部、认证边界内的幂等操作。当前 DataService proto 不存在，因此本计划在其 baseline
落地后必须刷新为精确 proto 路径；刷新前不得执行：

```proto
rpc EnsureVolumeSnapshot(EnsureVolumeSnapshotRequest)
    returns (EnsureVolumeSnapshotResponse);
rpc GetVolumeSnapshotOperation(GetVolumeSnapshotOperationRequest)
    returns (EnsureVolumeSnapshotResponse);
rpc OpenVolumeSnapshot(OpenVolumeSnapshotRequest)
    returns (OpenVolumeSnapshotResponse);
```

请求必须绑定：

```text
operation_id, snapshot_id, volume_id
expected_volume_revision, expected_write_epoch
expected_placement_revision, expected_replica_generations
```

成功结果由 DataService 产生，客户端不可提供：

```text
source_write_epoch, source_committed_sequence
snapshot_root_digest, catalog_generation, catalog_root_digest
protected_replica_ids, replica_attestations, certificate_digest
```

同 operation ID 不同参数是 protocol conflict；同参数重试必须返回已持久化的同一结果。
Open 只签发 read-only session，绑定 snapshot ID、root digest、protection revision 和 Replica
generation；不能复用 source Volume lease 或 writable namespace。

当前工作树关键 checksum：

```text
146c7539c6f5189f950aef963e02e4fe6de22bdac23d95347d82d950d7799a6e  docs/v3-multivolume-format.md
65a5b364e707c37d394b78b35f1548c75a21290efaee34a67b24a2f09373a383  services/zettide/v3/control_record.zig
a725cca18741e9c2fffbdd8712ff02c2ef9809d290f7029ca4165f01e048d32b  services/zettide/v3/replica_endpoint.zig
74b39865d28ccfa88d516c727c74d6503de457ae49b977d7c60d4d7793d8268e  services/zettide/v3/pool_replicated_journal.zig
c2bc317b69eb3959c0a704d5bc5958625ceae761884dcd2236cabef2c8c38d96  services/zettide/v3/pool_catalog.zig
557c6f09fac841580e9b9003d960196e55d84f62a15c58dbb5c2d0527ee23528  services/zettide/volume.zig
```

## 需要使用的命令

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Control tests | `zig build test --summary all` in `services/control/` | all pass |
| Unit tests | `zig build test-unit --summary all` in `zettide/` | all pass |
| Image tests | `zig build test-image --summary all` in `zettide/` | all pass |
| Fault tests | `zig build test-fault --summary all` in `zettide/` | all pass |
| CI gate | `zig build ci --summary all` in `zettide/` | all pass |
| Control diff | `git -C zettide-control diff --check -- proto src README.md` | exit 0 |
| Data diff | `git -C zettide diff --check -- src docs build.zig test` | exit 0 |

## 临时目录约定

- 测试镜像和 fault-injection scratch 必须使用 `$HOME/tmp` 或测试 harness 的 ignored temp dir。
- 不要把磁盘镜像或生成 proto 提交到仓库。

## 范围

**范围内**：

- `services/control/proto/zettide/control/v1/control.proto`
- `services/control/src/service.zig`
- `services/control/src/root.zig`
- `services/control/src/integration_test.zig`
- DataService baseline 落地后刷新出的精确 reconciler、observed-state、proto 和 client 文件
- `services/zettide/v3/replica_endpoint.zig`
- `services/zettide/v3/control_record.zig`
- `services/zettide/v3/pool_replicated_journal.zig`
- `services/zettide/v3/pool_catalog.zig`
- `services/zettide/v3/snapshot_root.zig`（新建，名称可按现有模块约定调整一次）
- `services/zettide/v3/volume_snapshot.zig`（新建，名称可按现有模块约定调整一次）
- `services/zettide/root.zig`
- 与上述模块直接对应的 unit/image/fault tests

**范围外**：

- snapshot delete 和 extent reclaim（计划 004）。
- clone、restore、application consistency、consistency group。
- 把 snapshot 数据复制经 Raft 或 grpc-lite 传输。
- 修改 3 replicas、2/3 quorum 的保护模型。
- 使用单 Replica root 或 wall-clock timestamp 作为 READY 依据。

## Git 工作流

- Branch: `advisor/003-volume-snapshot-data-plane`
- 按 format codec、local publication、quorum operation、reconciler wiring、public route 分 commit。
- Commit 风格示例：`feat: define pool authority checkpoints`。
- 不要 push 或创建 PR，除非 operator 明确要求。

## 步骤

### 步骤 1：实现 versioned SnapshotRoot codec

在计划 001 冻结的完整 offset table 上实现固定大小、CRC32C 校验、BLAKE3 digest 和
reserved-zero 检查。若文档仍未给出 magic、size、offset、digest domain、catalog root version、
certificate encoding 和 v1 migration，保持 BLOCKED。
SnapshotRoot 至少绑定：snapshot ID、source Volume ID、logical size、source Volume generation、
extent-map root reference、filesystem/header root reference、source write epoch、committed sequence、
creation operation ID 和 previous/format metadata。

Codec 只能表达候选数据；它自身不是 authority。解码必须拒绝零 ID、零 epoch、越界 page
reference、非零 reserved bytes 和 digest mismatch；sequence 允许为 0，表示空 committed prefix。

**验证**：`zig build test-unit --summary all` exit 0；测试源码包含 `SnapshotRoot golden`、
`SnapshotRoot sequence zero`、bit-flip、truncation、reserved bytes、bad reference 和 version。

### 步骤 2：增加持久 snapshot catalog 与 extent pinning

扩展 Pool catalog，使 snapshot ID 能查到 immutable SnapshotRoot，并使 allocator 能证明每个
physical extent 被 active Volume、一个或多个 snapshots、或 retired/quarantine 集合引用。
不得只保存在内存 refcount；reopen 必须从 authority-selected root 重建同一引用关系。

对 active Volume 覆盖一个被 snapshot pin 的 extent，实现 redirect-on-write：分配新 extent，
复制未覆盖数据，应用新写，持久化 data，COW 更新 active extent map 和 allocator，再提交新的
catalog root。旧 extent 保持只读并继续属于 snapshot。

Publication 顺序必须保持：data durable -> metadata pages durable -> root copy durable -> control
generation prepare/commit。Unknown control outcome freeze mutation 并 reopen authority，禁止猜测。

**验证**：`zig build test-image --summary all && zig build test-fault --summary all` exit 0；
snapshot 后覆盖各 extent 边界，重开后 snapshot bytes 不变，active Volume 看到新数据；每个
publication fault point 只恢复旧 root 或新 root。

### 步骤 3：实现 primary capture barrier

同一 Volume 的 snapshot 与 fencing/recovery/placement change 串行。执行顺序固定为：

1. 验证 current lease、epoch、placement revision 和 Replica generations。
2. 验证 Create intent 中三个 initial SnapshotReplicaReservations 仍匹配 source placement；在
   每个目标 local catalog 以 reservation/operation ID 幂等建立 snapshot owner，状态进入
   MATERIALIZING。未预留 owner 一律拒绝。
3. 停止接受 barrier 之后的新 write sequence。
4. disconnect/drain 不必要；正常 snapshot 不推进 epoch，但必须 drain 已接受 I/O。
5. 对唯一 unresolved sequence 做协议恢复，确定 committed 或 aborted。
6. 固定连续 `(write_epoch, committed_sequence)`，sequence 允许为 0。
7. 合并任意 recovery quorum 的 certified histories；不能假设单个 Replica 持有完整 prefix。
8. 将 boundary 以内每个缺失 payload/certificate write-back 到 snapshot protection set 的至少
   两个 Replica，并逐 sequence/range 校验连续性与 checksum。
9. 在这些已物化完整 prefix 的 reserved Replica owner 上持久化相同 SnapshotRoot 和 extent pins。
10. 形成 certificate，并在至少两个匹配 prepare/payload 的 Replica 上持久化。
11. Complete command 激活 attested reservation；未激活 reservation 保留给 reconciler 清理。
12. 恢复新写；之后所有共享 extent 写入走 COW。

若 lease 进入不安全窗口、generation 变化、root digest 分歧或 certificate 只持久化一份，保持
Volume fail-closed；不能返回成功或把 snapshot 标为 READY。

**验证**：`zig build test-fault --summary all` exit 0；新增测试必须覆盖 write 1 在 A+B、write 2
在 B+C 的轮换 quorum，证明 write-back 后至少两个 protection Replica 都含完整连续 prefix。

### 步骤 4：实现幂等 DataService operation

DataService 在本地持久 catalog 中以 `(snapshot_id, operation_id)` 查找状态。重试行为：

- 已完成：返回同一 root/certificate。
- 已准备未完成：从 Replica quorum 查询并完成 certificate 或安全回滚不可达候选。
- 参数不同：返回 protocol conflict。
- outcome unknown：先 authority reopen，再决定，不创建第二个 root。

响应中的 attestation 必须绑定 current Replica ID/generation、operation、root digest、epoch 和
sequence。Control reconciler 验证两个不同 current Replica 的 attestation 后才能 propose
`CompleteVolumeSnapshot`。

**验证**：`zig build test-fault --summary all` exit 0；response loss、primary crash、control
leader change 和相同 operation retry 都收敛到同一 snapshot ID/root digest。

### 步骤 5：实现只读 snapshot 数据路径

从 snapshot protection set 选择已物化到 certified boundary 的合格 Replica，发布 read-only
namespace/session。每次 open 绑定 snapshot ID、root digest、protection revision 和 Replica
generation；session 不携带 source Volume lease，也不允许普通 write/vendor mutation command。
若只能证明一份完整副本，availability 为 READ_ONLY 并按策略只读；若无法证明完整 root，返回
UNAVAILABLE，不能从 rebuilding/stale Replica 拼读。

**验证**：`zig build test-linux-block -Dblock-tests=required --summary all` exit 0，且 snapshot
子测试验证 open/read、write rejection、source Volume 删除后读取和 stale generation rejection。

### 步骤 6：实现 snapshot-owned allocation 与 protection repair

Reconciler 不因瞬时 heartbeat 丢失修改 durable protection set。确认 Replica 永久丢失或进入
replacement 后，先通过 `BeginVolumeSnapshotProtectionRepair` 调用阶段 8 已落地的 placement 和
extent allocator，在不同故障域预留 snapshot-owned Replica ID、Node/Member allocation 和新
generation。DataService 以 reservation/repair operation ID 幂等创建本地 catalog owner，把同一
immutable root 和完整 committed prefix materialize 到新 Replica，并持久化 root/certificate
attestation；随后 proposal `UpdateVolumeSnapshotProtection` 原子切换成员。旧 Replica 必须先由
generation/epoch fence，再持久化 tombstone/quarantine，最后才能
`FinalizeVolumeSnapshotReplicaRetirement`，不能在新 protection revision 下重入或提前 free。

Capture 建立初始 protection set 时使用 Create intent 已经 Raft-committed 的
SnapshotReplicaReservations，不能在 DataService 中临时生成 identity。即使物理 extent 暂时与
source Replica 共享，local catalog owner/refcount 也分别记录 source owner 和 snapshot owner。
Source Volume 删除只撤销 source owner；snapshot root、allocation ownership 和 repair target
selection 不依赖 source placement。

API availability 由 durable protection set 与当前 observations 合并：3 complete replicas 为
HEALTHY，2 为 DEGRADED，1 为 READ_ONLY，0 为 UNAVAILABLE。Repairing Replica 在完成 root、
boundary 和 digest 校验前不计入 complete set。

**验证**：`zig build test-fault --summary all` exit 0；测试覆盖 placement failure、overlapping
allocation rejection、reservation 后 crash/retry、3->2、2->3 replacement、source Volume 删除后
repair、stale completion、旧 generation rejoin 和 leader change，并在 Raft snapshot/restart 后
保留 reservation 与最新 protection revision。

### 步骤 7：接通 reconciler 并开放 public Create

Reconciler 对一致 revision 读取 `CREATING` snapshot 和 source Volume desired state，合并最新
observed/persistent facts，生成带 expected revision/generation 的 Ensure action。旧 leader 的
completion 或 stale action 在 state machine 中必须被拒绝。

只有端到端 tests 证明 READY 证据链后，才在 `VolumeSnapshotService.register()` 注册 public
Create/Get/List routes。Create 仍只返回 CREATING；客户端通过 Get/List 观察 READY。

**验证**：`zig build test --summary all` 在 `services/control/` exit 0；三 voter failover + primary
response loss 最终只产生一个 READY snapshot。Route grep 至少命中 register 与测试 expectation。

## 测试计划

- Codec：round-trip、malformed、future version、digest/CRC、reference bounds。
- COW：active overwrite、partial extent write、thin hole、out-of-space、reopen、snapshot bytes
  immutable。
- Barrier：concurrent write、unresolved prepare、single certificate candidate、two-certificate
  commit、rotating quorums、history write-back、lease expiry、epoch/generation mismatch。
- Read：read-only open、write rejection、source deletion、degraded read、stale generation。
- Protection：initial intent reservation、placement/allocation reservation、member loss、replacement materialization、
  attested set update、old generation fencing、source-independent ownership。
- Idempotency：response loss、same operation retry、different parameters conflict。
- Control：leader stepdown before/after Complete proposal、stale observed state、ReadIndex Get。
- Fault injection：每个 data/page/root/prepare/certificate sync 前后断电。

验证命令为本计划“需要使用的命令”中全部五个 build/test gate。

## 完成标准

- [ ] snapshot root 有 versioned、checksummed、digest-bound 持久格式。
- [ ] 后续 active writes 不能修改任一 snapshot 可达数据。
- [ ] READY 精确绑定 source generation、epoch、committed sequence、root 和两份 certificate。
- [ ] 至少两个 protection Replica 已 materialize 完整 committed prefix，而不是只各持有子集。
- [ ] snapshot 有可验证的 read-only 数据路径，且不依赖 source Volume placement/lease。
- [ ] 同 operation retry 不创建第二个 snapshot root。
- [ ] unknown outcome 必须 freeze/reopen，不猜测成功或失败。
- [ ] public Create/Get/List routes 已在端到端证据链完成后注册。
- [ ] control、unit、image、fault 和 ci gates 全部通过。
- [ ] 没有修改范围外文件。

## STOP 条件

- Replica write protocol 仍没有 epoch/sequence/prepare/certificate。
- 当前计划状态仍为 BLOCKED，或未按 baseline 刷新 exact proto/files/symbols。
- 数据面无法提供 quiesce/drain 和 authoritative committed frontier。
- Pool catalog 尚不能 COW publication 或 pin recoverable roots。
- 阶段 8 尚未提供 durable placement/allocation reservation、replacement 和 quarantine。
- 需要把整个 Volume 长时间停写复制才能保留历史数据。
- Flush/FUA/volatile cache 的持久语义无法验证。
- 两个 Replica 对同一 operation 返回不同 root digest 或 sequence。
- 实现需要把 snapshot payload 经 Raft/grpc-lite 复制。

## 维护说明

Reviewer 应沿着 `Raft READY -> certificate digest -> two Replica attestations -> SnapshotRoot ->
pinned extents` 反向验证完整证据链。未来更改 extent size、catalog root version、write pipeline
或多 unresolved sequence 时必须重审 barrier 与 COW publication，不得只更新 codec。
