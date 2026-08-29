# 0002：首轮提取后保持单一 Storage Engine Package

- 状态：Accepted
- 范围：`libs/storage-engine/` 的第二阶段 package 边界
- 前置决策：[0001：存储节点命名与进程模型](0001-storage-node-naming-and-process-model.md)

## 背景

`services/zettide/` 已按进程职责拆为 `libs/storage-engine/` 与 `services/node/`。
反向 platform import 已移除，engine 具有独立 `zettide_storage` module、build、test 和 cross
compile gate。首轮完成后需要重新判断是否立即把 Pool、Catalog、Blob、BlobFilesystem 或
foundation 继续拆成独立 package。

本次评估基于迁移后的实际源码图，而不是迁移前目录大小：

- engine 当前有 61 个 Zig 文件，约 41,742 行；
- 全图约有 341 条 engine 内部相对 import，去除 top-level test 后约 324 条；
- Pool/Catalog production path 不再 import Blob/BlobFilesystem；现有 Pool -> Blob import
  位于跨层 reopen/integration tests；
- 唯一可见的双文件环是 `pool_member_set.zig` test fixture 对
  `pool_provision.zig` 的回引，不是 production runtime 环；
- proposed foundation 仍有 `control_record.zig -> topology.zig` 的持久格式依赖，尚未形成
  完全向下的独立 package DAG；
- 仓库已有约 34 个显式 `zettide_storage` consumers，分布于 node adapters、tests 和
  benchmarks；public root 目前公开约 20 个顶层 declaration，`v3` root 公开约 36 个；
- engine 的格式、reopen、corruption 和 cross-domain tests 共享同一个格式版本与发布周期。

源码规模已经足以支持内部领域分层，但不足以单独证明应该增加 package、版本和构建边界。

## 决策

本阶段**不继续拆分独立库**。继续保留：

- 一个 package：`libs/storage-engine/`；
- 一个 public Zig module：`zettide_storage`；
- 一个独立 build/test owner：`libs/storage-engine/build.zig`；
- Pool/Member/Catalog、Blob/BlobFilesystem、backend-neutral filesystem API 和所属持久格式
  在同一兼容版本与发布单元中演进。

这不是放弃分层。package 内继续遵守
[组件依赖与分层规则](../architecture/zh-CN/component-dependencies.md)：

1. foundation contract 不得依赖 node、SPDK、FUSE、CLI、RPC 或 controller；
2. Pool production path 不得解释 Blob header/chunk geometry；
3. 持久格式继续归所属领域，不建立独立 `libs/formats`；
4. node/platform consumers 只通过 public `zettide_storage` module 使用 engine；
5. integration tests 可以跨领域验证 reopen，但必须与 production import 方向明确区分。

可以先在 package 内建立更窄的 internal roots、test roots 和 namespace；不得仅为缩短文件列表
创建新的 repository package。

## 暂不拆分的原因

### Foundation 尚不是独立 DAG 底层

`storage`、`codec`、checksum 和 name profile 是候选 foundation，但
`control_record -> topology` 仍绑定 Pool format。现在拆出 foundation 会迫使建立反向 package
依赖、复制 format 类型，或过早设计额外 compatibility facade。

### Pool 与 Blob 的边界已足以由 module 规则表达

D1-D4 已解除，Pool production path 不依赖 Blob 实现。当前剩余跨域引用主要用于同 package
integration tests。先保持一个 package 可以继续验证 Pool-backed Blob reopen，而不把 test-only
关系固化成发布依赖。

### Consumers 仍需要组合视图

node target composition、NFS backend、SPDK adapters 和 benchmarks 经常同时使用 Storage port、
Pool data adapter、Blob 或 filesystem API。立即拆包会增加 module injection 和 compatibility aliases，
但不会减少进程权限、磁盘格式耦合或发布风险。

### 兼容风险高于当前收益

Pool、Catalog 和 Blob 格式仍共享 v3 compatibility lifecycle。独立 package 会新增版本组合矩阵，
却没有独立部署 artifact、独立 owner 或独立 release cadence 作为收益。

## 重新评估条件

满足以下条件后再提出独立 package ADR；单纯 LoC 增长不是充分条件：

1. **稳定 DAG**：production imports 形成明确单向图，foundation 不再反向依赖 Pool/Blob format；
2. **独立 consumers**：出现只需要 Pool/Catalog 或只需要 Blob/filesystem 的仓库外消费者，且不应
   获得另一领域 API；
3. **独立验证**：候选组件能在不递归 import sibling test namespace 的情况下完成 format、reopen、
   corruption 和 cross-target gates；
4. **独立演进**：组件具有不同 owner、release cadence 或依赖策略，拆包能实际减少变更影响面；
5. **组合成本可控**：root build、node、NFS、SPDK、benchmarks 不需要重新建立 mega compatibility
   facade；
6. **格式策略明确**：拆包不复制 persisted type，不改变 magic/version/offset/checksum，也不引入
   隐式格式版本组合。

## 候选实施顺序

若未来条件满足，按以下顺序进行，而不是同时拆多个 package：

1. 将 test-only cross-domain imports 收敛到独立 integration roots；
2. 消除 `control_record -> topology` 等 foundation 反向 format seam；
3. 在 `libs/storage-engine/` 内先建立并验证窄 internal module roots；
4. 统计真实 external consumer surface 与编译收益；
5. 优先提取无 persisted ownership 的 foundation contract；
6. 再分别评估 Pool/Catalog 和 Blob/BlobFilesystem，且每次只移动一个边界。

## 结果

- 本轮不新增 `libs/storage-foundation/`、`libs/pool/`、`libs/catalog/` 或 `libs/blob/`；
- 不改变磁盘格式、CLI、endpoint wire API、NFS ABI 或 SPDK identity/lifecycle；
- `zettide_storage` 保持唯一 public engine module；
- 后续内部整理必须继续通过 `test-storage-engine`、`test-module-roots`、`test-cross` 和
  library-local `zig build ci`。
