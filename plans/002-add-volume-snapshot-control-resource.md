# 计划 002：增加 VolumeSnapshot 控制面资源

> **执行者说明**：本计划实现控制面 schema、确定性状态机与管理 API，但不执行介质操作。
> 开始前必须确认 `Volume` baseline 已经落地；否则按 STOP 条件报告 BLOCKED。
>
> **漂移检查（首先运行）**：
> `git -C zettide-control diff --stat c25ed1d..HEAD -- proto src README.md build.zig`
> 执行前运行
> `sha256sum proto/zettide/control/v1/control.proto src/state_machine.zig src/service.zig src/root.zig`
> 并确认结果分别为
> `2f390f2338626d2c28250957ba98ba6f19fefca4d4f03b2794ec81b1c8e899b2`、
> `4fa351a90b955ccc0d6b64e7fa300ca75774b56b91f11df5ec08ba78543ebee8`、
> `d3aa724f80655490eb7728c1ac431d8ff445ec205c3a7df598780a388d3b34ab`、
> `3c7f4546276bb62f4f3dcf157373ed692775e14ffb21fc4977c614cf5cf26943`；
> 任一不匹配都先刷新本计划。不要回退这些修改。

## 状态

- **优先级**: P1
- **工作量**: L
- **风险**: HIGH
- **依赖**: `plans/001-freeze-volume-snapshot-contract.md`、Volume baseline
- **类别**: direction, tech-debt
- **Status**: BLOCKED（等待 Volume baseline，并在其落地后刷新文件路径与符号）
- **计划生成于**: `zettide-control` commit `c25ed1d`, 2026-07-29

## 为什么重要

快照必须是 Raft 中的第一类 durable resource，才能在 control leader 切换、响应丢失和
reconciler 重试后保持同一 identity。该计划只表达 desired state 和经过验证的结果，不在
Raft apply 中调用 DataService。这样可以保持状态机确定性，并让 public API 明确区分
“已接受创建”与“数据已 READY”。

## 当前状态

- `control/proto/zettide/control/v1/control.proto:5-9`：只有 `PoolService`。
- `control/proto/zettide/control/v1/control.proto:50-79`：command/result 只支持
  `CreatePool`。
- `control/proto/zettide/control/v1/control.proto:89-93`：Raft snapshot 只保存 Pool
  与 request history。
- `control/src/state_machine.zig:78-95`：内存状态只有 Pool 索引和 requests。
- `control/src/state_machine.zig:187-272`：apply 硬编码单一 CreatePool command。
- `control/src/state_machine.zig:499-612`：restore request 与 response 校验也硬编码
  CreatePool；未来 delete 不能假设 created resource 永远仍在 live map。
- `control/src/state_machine.zig:630-707`：command/snapshot preflight 严格拒绝未知
  internal fields。
- `control/src/service.zig:51-186`：mutation 走 propose，Get/List 走 ReadIndex。
- `control/src/service.zig:368-372`：RPC route 当前仅注册 Pool 三个方法。

必须沿用现有模式：leader 在 proposal 前生成 UUIDv7 和时间；apply 只做有界内存状态变更；
业务冲突编码为 deterministic result；Get/List 走 ReadIndex；输入先经过严格 wire preflight。

## 目标 API

在版本化 proto 中定义独立服务：

```proto
service VolumeSnapshotService {
  rpc CreateVolumeSnapshot(CreateVolumeSnapshotRequest)
      returns (CreateVolumeSnapshotResponse);
  rpc GetVolumeSnapshot(GetVolumeSnapshotRequest)
      returns (GetVolumeSnapshotResponse);
  rpc ListVolumeSnapshots(ListVolumeSnapshotsRequest)
      returns (ListVolumeSnapshotsResponse);
}
```

`CreateVolumeSnapshot` 在 intent apply 后返回 `CREATING`。本计划结束时不要注册 public Create
route；计划 003 在 DataService/reconciler 完成接线后注册，避免发布永远无法 READY 的 API。

核心资源字段：

```text
id, source_volume_id, name, description
consistency_mode = CRASH_CONSISTENT
lifecycle_state = CREATING | READY | FAILED
availability_state = UNKNOWN | HEALTHY | DEGRADED | READ_ONLY | UNAVAILABLE
operation_phase = CAPTURING | NONE | REPAIRING
source_volume_generation, source_write_epoch, source_committed_sequence
snapshot_root_digest, certificate_digest
protection_revision, protected_replica_ids, protected_replica_generations
snapshot_replica_allocations(node_id, member_id, allocation_id, generation)
created_at_unix_ms, created_revision, ready_revision, resource_version
failure_code
```

所有 digest 固定 32 bytes；failure 使用有界 enum，不持久化任意远端错误字符串。

## 需要使用的命令

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `zig build gen-proto` | exit 0 |
| Tests | `zig build test --summary all` | all tests pass |
| Diff | `git diff --check -- proto src README.md build.zig` | exit 0 |
| Routes | `grep -n "VolumeSnapshotService/CreateVolumeSnapshot" src/service.zig` | no match before plan 003 |

命令工作目录均为 `control/`。

## 临时目录约定

- 临时文件只能放在 `$HOME/tmp`。
- `.zig-cache/` 和 `zig-out/` 只能作为构建产物，不得提交。

## 范围

**范围内**：

- `control/proto/zettide/control/v1/control.proto`
- `control/src/state_machine.zig`
- `control/src/service.zig`
- `control/src/protobuf_wire.zig`
- `control/src/root.zig`
- `control/src/integration_test.zig`
- `control/README.md`

**范围外**：

- `zettide/` 数据面文件。
- public Delete、clone、restore。
- application consistency。
- 在 apply 中进行 RPC、I/O、flush 或等待。
- 与 snapshot 无关的 Pool API 重构。

## Git 工作流

- Branch: `advisor/002-volume-snapshot-control-resource`
- 每个可独立验证的 schema/state-machine/service 逻辑单元一个 commit。
- Commit 风格示例：`control: implement replicated pool state`。
- 不要 amend、push 或创建 PR，除非 operator 明确要求。

## 步骤

### 步骤 1：确认 Volume baseline 与兼容策略

执行者必须先确认状态机已有 durable `Volume`，至少能读取：ID、lifecycle、revision、
generation、write epoch、placement revision。Create intent 只能针对 `Active` 且不在 fencing、
recovering、deleting 的 Volume。

内部 wire 采用协调升级：新二进制可读取旧 command format v1 和 state snapshot format v2，
写出新版本；旧二进制不能加入开始写新 command 的集群。当前没有软件版本协商，因此不要
声称支持 mixed-version rolling upgrade。

**验证**：`zig build test --summary all` exit 0，且名为 `legacy command and snapshot fixtures restore`
的测试通过；若测试 harness 支持 filter，再单独运行对应 filter。

### 步骤 2：扩展 proto 资源和内部 command

增加 public resource/request/response，以及以下 internal commands：

```text
CreateVolumeSnapshotIntent
CompleteVolumeSnapshot
FailVolumeSnapshot
BeginVolumeSnapshotProtectionRepair
UpdateVolumeSnapshotProtection
FinalizeVolumeSnapshotReplicaRetirement
```

Create command 同时包含客户端语义字段和 leader 生成字段。Leader 必须在 proposal 前从当前
source placement 选择初始保护目标，并生成三个 `SnapshotReplicaReservation`：snapshot Replica
ID、target Node/Member、source Replica ID/generation、snapshot allocation generation 和 owner
reservation ID。Create intent apply 原子保存资源与这些 reservation；DataService capture 不能
使用未被 Raft intent 引用的 owner identity。Fingerprint 只覆盖客户端语义：
`source_volume_id`、`name`、`description`、`consistency_mode` 和客户端提供的 expected revision；
不覆盖 proposed ID、时间或 leader 解析出的 current epoch/generation。

Complete command 必须包含 `snapshot_id`、`operation_id`、expected resource version、source
generation/epoch/sequence、root digest、certificate digest、被激活的 reservation IDs、对应
Node/Member/allocation generations、protected Replica attestations 和 proposed completion time。
Apply 验证每个 attestation 精确对应 Create intent 的 initial reservation，再原子把至少两个
reservation 从 `RESERVED/MATERIALIZING` 激活为 protection members。Stale operation、未预留
owner、错误 generation 或不满足 quorum 的结果必须返回 deterministic precondition result。

Fail command 只接受 terminal、有界 failure enum。超时、leader change、暂时 quorum 不足不应
立即持久化为 `FAILED`，应继续 reconciliation。

`UpdateVolumeSnapshotProtection` 只作用于 READY snapshot，并包含 expected resource/protection
revision、旧/新 protection members、每个 Replica generation、同一 root/boundary 的 durable
attestations 和 proposed update time。只有新集合至少两个 Replica 已 materialize 完整 prefix、
持久化相同 root/certificate，且被移除 Replica 已由更高 generation fencing 后才能 apply。
瞬时 heartbeat 丢失不修改 durable protection set；Get/List 将 durable desired set 与 leader-local
observations 合并为 HEALTHY/DEGRADED/READ_ONLY/UNAVAILABLE。

`BeginVolumeSnapshotProtectionRepair` 由 leader 在 proposal 前运行既有 placement/allocator，生成
新的 snapshot Replica ID、Node/Member、非重叠 allocation、generation 和 repair operation ID，
并在 Raft 中条件预留。它不得复用 source Volume Replica identity。`Update...` 只在 DataService
对该 reservation 完成 materialization/attestation 后把新成员加入并把旧成员标为 retiring；
`Finalize...Retirement` 只在旧 generation 已 fencing、local catalog tombstone 和 quarantine
证明完成后释放旧 reservation。部分失败 reservation 保留并由 reconciler 幂等重试或 tombstone。

**验证**：`zig build gen-proto && zig build test --summary all` exit 0；测试源码中存在
`VolumeSnapshot proto round trip` 和 `VolumeSnapshot malformed wire is rejected`。

### 步骤 3：实现索引和状态转换

在单一 Raft state machine 内新增：

```text
snapshots_by_id
snapshot_id_by_source_and_name
snapshot_ids_by_source_and_revision
```

唯一名称作用域为 source Volume。List 必须要求 `source_volume_id`，以创建 revision 和 ID 形成
稳定顺序；page token 使用 opaque versioned encoding，不只存裸 revision，避免同 revision 或
未来过滤条件造成歧义。

Apply 规则：

- Create 检查 Volume 仍匹配 expected revision/generation/epoch 且状态允许，原子插入
  `CREATING + UNKNOWN + CAPTURING`。
- Complete 只允许当前 operation 从 `CREATING` 转到 `READY`，保存 certified boundary，激活
  Create intent 已预留且有 attestation 的 SnapshotReplicaAllocations，并建立初始 protection revision。
- Fail 只允许当前 operation 从 `CREATING` 转到 `FAILED + UNAVAILABLE`。
- UpdateProtection 只允许 READY 保持 READY，原子替换 protection set 并增加 protection revision；
  stale revision、root/boundary 变化、少于两个 complete Replica 或未 fencing 的旧 generation
  返回 deterministic precondition result。
- BeginRepair 原子预留 snapshot-owned allocation；FinalizeRetirement 只能撤销不再承担最新
  protection revision 的旧 generation，且遵守既有 allocation quarantine 规则。
- 所有 transition 增加 `resource_version`，revision 取 entry index。

实现必须预分配所有 map/list/request memory，再使用 assume-capacity 提交，保持 OOM 下 apply
原子性，沿用 `state_machine.zig:238-271` 的现有模式。

**验证**：`zig build test --summary all` exit 0；测试源码至少包含命名片段
`snapshot transition`、`snapshot request conflict`、`stale snapshot completion`、
`snapshot protection repair reservation`、`snapshot protection update`、
`snapshot replica retirement` 和 `snapshot apply allocation failure is atomic`。

### 步骤 4：扩展 Raft state snapshot 与恢复验证

新 state snapshot 确定性排序 VolumeSnapshot 和 requests。恢复时验证：

- CREATING snapshot 的 source Volume 必须存在且关系合法；READY snapshot 固化 source identity
  和独立 protection set，source Volume 已删除时可由 Volume tombstone 或 snapshot 内的 frozen
  source identity 验证，不能要求 live source 永远存在。
- `(source_volume_id, name)` 唯一。
- READY 必须有非零 epoch、允许 sequence 为 0、32-byte root/certificate digest，以及至少
  两个不同且 generation 明确的 snapshot protection Replica IDs。
- CREATING 不得伪装为已有 certificate。
- revision 不超过 Raft snapshot metadata index。
- request command/fingerprint/response 能由 live resource 解释。

恢复仍必须先构造临时 state，全部验证后一次替换 live state，沿用
`state_machine.zig:346-398`。

**验证**：`zig build test --summary all` exit 0；测试源码包含 deterministic snapshot、legacy
restore、READY snapshot without live source、corrupt protection set 和 OOM atomic restore。

### 步骤 5：实现未注册的管理 service 方法

实现 Create/Get/List service 方法和 unit-level dispatcher tests，但暂不在 `register()` 中暴露
Create route。Create handler 应先 ReadIndex 获取当前 Volume 前置值，再 proposal；apply 时再次
条件校验。Get/List 走 ReadIndex。

推荐错误映射：

| Condition | gRPC status |
|-----------|-------------|
| invalid wire/field | `INVALID_ARGUMENT` |
| source Volume missing/snapshot missing | `NOT_FOUND` |
| name exists | `ALREADY_EXISTS` |
| Volume state or expected revision mismatch | `FAILED_PRECONDITION` |
| request ID conflict | `FAILED_PRECONDITION` |
| resource/request limit | `RESOURCE_EXHAUSTED` |
| follower/leadership lost | `UNAVAILABLE` |

**验证**：service tests 覆盖 follower gate、ReadIndex、accepted CREATING response、重复 request、
stale volume revision 和 pagination；`zig build test --summary all` exit 0，Routes 命令无匹配。

## 测试计划

- 以 `src/state_machine.zig` 现有 idempotency、deterministic snapshot、corruption 和 failing
  allocator tests 为结构模板。
- 以 `src/service.zig` 现有 Pool Create/Get/List tests 为 service 模板。
- 以 `src/integration_test.zig` 的 snapshot + WAL suffix replay 为恢复模板。
- 至少覆盖 Create happy path、name conflict、request conflict、source state conflict、stale
  completion、wrong operation ID、one-Replica certificate rejection、deterministic restore、v2
  snapshot migration 和 pagination token tampering。

验证：`zig build test --summary all` 全部通过。

## 完成标准

- [ ] public proto 可以表达 VolumeSnapshot 与 Create/Get/List。
- [ ] 内部 command 可以创建 intent、完成和 terminal fail。
- [ ] Create intent 先原子预留 initial SnapshotReplicaAllocations，Complete 只能激活这些 reservation。
- [ ] protection set 可在 repair/replacement 后以 attested、revision-conditional command 演进。
- [ ] 每个 protection member 有 snapshot-owned Replica/allocation identity，source Volume 删除后
  ownership、repair 和 delete 均不依赖 source placement。
- [ ] apply 不执行外部 I/O，所有业务冲突是 deterministic result。
- [ ] READY 必须绑定 source generation/epoch/sequence、root 和 quorum certificate digest。
- [ ] 新二进制能恢复旧 command/state snapshot fixtures。
- [ ] public Create route 尚未注册。
- [ ] `zig build test --summary all` exits 0。
- [ ] 没有修改范围外文件。

## STOP 条件

- durable Volume model 尚不存在，或不含 revision/generation/write epoch。
- 当前计划状态仍为 BLOCKED，且尚未按已落地 Volume baseline 刷新精确文件与符号。
- 计划 001 的 snapshot contract 尚未完成或与 proto 字段冲突。
- 实现要求在 Raft apply 中调用 DataService。
- 团队要求 mixed-version rolling upgrade，但仓库仍无版本协商/feature gate。
- READY 无法验证至少两个当前 generation Replica 的 certificate evidence。
- 需要顺手重写 Pool API/state machine 才能完成；先单独规划该重构。

## 维护说明

未来增加 Delete 时，request restore 不能继续假设 Create response 引用的资源永远在 live map；
必须通过 tombstone 或等价历史证明验证。Reviewer 重点检查 fingerprint 是否遗漏客户端语义字段，
以及 Complete command 是否能被旧 operation 或旧 generation 重放。
