# 0001：存储节点命名与进程模型

- 状态：Accepted；package/module/目录迁移已实施，完整 `zettide-node` daemon composition 待完成
- 范围：`services/node/` 重构以及后续数据节点演进

## 背景

重构前，旧 `services/zettide/` 不是一个单一 service，而是同时包含：

- Pool、Member、Catalog、Blob 和 BlobFilesystem 的持久格式与存储引擎；
- backend-neutral filesystem API；
- Linux、FUSE、NFS、dufs 和 SPDK adapter；
- endpoint registry、owner-only control API 和 endpoint daemon；
- `zettide` 命令行入口；
- 尚未接入根构建的 DataService 与 `node_main.zig`。

因此，仅把目录改成另一个 service 名称不能形成清晰边界；直接拆成多个细粒度
package 又会固化当时的反向依赖。当前已按本决策拆为 `libs/storage-engine/` 与
`services/node/`，并保留兼容 CLI；DataService/endpoint 的单 NodeContext owner 仍按本决策继续实施。

## 决策

### 1. 源码组件

最终源码布局采用角色名：

| 路径 | Zig module/package | 职责 |
| --- | --- | --- |
| `libs/storage-engine/` | `zettide_storage` / `zettide-storage-engine` | backend-neutral 存储引擎、持久格式、Pool/Member/Catalog、Blob/BlobFilesystem |
| `services/node/` | `zettide_node` / `zettide-node` | 受管 storage node 的进程组合、DataService、endpoint reconciliation、Linux/SPDK/frontend 集成 |
| `services/controller/` | `zettide_controller` / `zettide-controller` | Raft 权威元数据与 reconciliation 控制面 |

旧 `services/zettide/` 只是迁移源路径，不是最终组件名。品牌名 `Zettide` 不再用作一个
同时代表库、service 和 executable 的源码边界；源码现已分流到 `libs/storage-engine/` 与
`services/node/`。

首轮只提取一个 `storage-engine` 库。除非后续依赖图已经单向且存在独立消费者，
不得提前把 Pool、Catalog、BlobFilesystem 拆成彼此依赖的小 package。

### 2. 安装产物

最终保留两个数据面 executable 角色：

- `zettide`：管理员和本地 standalone 操作工具；
- `zettide-node`：长期运行的受管数据节点 daemon。

`zettide-controller` 继续作为独立控制面 daemon。

源码目录、Zig module 和 executable 不要求同名。将代码迁移到
`libs/storage-engine/` 或 `services/node/` 不得隐式重命名现有用户命令。

### 3. `zettide` CLI

`zettide` 继续负责显式、由调用者拥有生命周期的操作：

- inspect、plan、format、check 等离线或管理操作；
- standalone Blob file/Pool 的 foreground FUSE mount；
- `serve dufs` 便利适配。

CLI 可以链接 `zettide_storage`，但不是存储引擎的 module root，也不是受管 Node 的
权威状态持有者。长期运行、需要 controller reconciliation 的能力不得继续新增到
CLI 中。

当前 `zettide endpoint serve` 在迁移期作为兼容入口保留。它是
`zettide-node` 接管 managed endpoint lifecycle 之前的过渡路径，不是最终独立 service
边界。移除或转发该入口需要单独的兼容决策与 release note。

### 4. `zettide-node` daemon

最终每个受管 storage node 运行一个 `zettide-node` 进程。该进程组合：

- DataService RPC；
- stable Node/boot identity 与本地 authority 状态；
- Member、Replica 和 Pool/Catalog 的本地 lifecycle；
- endpoint desired/observed state reconciliation；
- SPDK runtime、Catalog backend 及 NVMf/iSCSI/vhost export；
- 后续 Tier 3 Volume Engine 和 internal Replica transport。

DataService 是 controller 到 storage node 的管理边界；endpoint 是 node 内部的
publication primitive，不再定义第二个长期运行的产品 daemon。一个 Node 进程可以管理
多个 Pool 和 Volume，但同一物理资源仍必须只有一个 owner。

`node_main.zig` 和 `node_data_service.zig` 表示该目标 service 的早期实现。它们在依赖、
持久状态和 endpoint reconciliation 接通之前不得被描述为完整 node daemon。

### 5. 前端进程边界

- SPDK endpoint/export 运行在 `zettide-node` 内，避免多个进程争用 reactor、bdev 或
  Pool ownership。
- NFS-Ganesha 保持独立进程；`FSAL_ZETTIDE` 通过稳定 C ABI 调用 Zettide NFS backend。
- foreground FUSE mount 和 `dufs` 仍由显式 `zettide` 命令拥有，不自动并入 node daemon。
- 未来 managed FUSE/NFS lifecycle 可以由 node reconciliation 发起，但不能因此把
  Ganesha 或每个 mount 的执行线程隐式塞入存储引擎库。

### 6. 库边界

`zettide_storage` 必须：

- 不启动监听 socket、解析产品 CLI 或处理进程信号；
- 不拥有 controller/DataService RPC；
- 不依赖 endpoint daemon、FUSE、NFS-Ganesha 或 SPDK export；
- 通过显式 storage/filesystem/backend 接口接受平台 adapter；
- 保持磁盘格式和核心测试可在不启用 SPDK/FUSE 的构建中使用。

Linux file/block 和 io_uring 实现是否首轮随库迁移，由后续依赖图决定；即使源码位于库
package，它们也必须作为 platform adapter，不得反转核心依赖方向。

## 进程模型

```text
zettide-controller
    |
    | DataService RPC / desired authority
    v
zettide-node
    |-- local Pool/Member/Catalog ownership
    |-- SPDK runtime and managed block publications
    |-- endpoint reconciliation
    `-- future Volume Engine / Replica service

zettide (operator-owned command)
    |-- offline inspect/plan/format/check
    |-- foreground FUSE mount
    `-- foreground dufs convenience path

NFS-Ganesha (separate process)
    `-- FSAL_ZETTIDE -> stable C ABI -> BlobFilesystem backend
```

控制面不进入逐 I/O 路径。`zettide` CLI 也不作为 controller 与 node 之间的代理。

## 兼容约束

此次目录重构不得改变：

- on-media format、magic、version、checksum 或 layout；
- 现有 `zettide` 子命令和参数；
- endpoint Unix API version 及 wire representation；
- `zettide-nfs-backend` C ABI 和安装 header 路径；
- 现有 NQN、NSID、IQN/LUN、UUID 或其他稳定 identity 派生规则；
- build step 和测试名称，除非先提供迁移别名。

根构建可以暂时把旧 import 名 `zettide` 映射到新的库或 facade。兼容 alias 必须有明确
消费者清单，所有消费者迁移后再删除，不能永久形成第二套公共 API。

## 被拒绝的方案

### 只把 `services/zettide` 改名为 `services/node`

拒绝。这样仍会把可复用存储引擎和产品 daemon 混在一个 service 中。

### 把整个目录移动到 `libs/zettide`

拒绝。CLI、信号、socket、FUSE、SPDK runtime 和 daemon lifecycle 不是库职责。

### 立即拆成 Pool、Catalog、Blob、Filesystem、SPDK 多个 package

拒绝作为首轮方案。当前 `v3`、Blob 和测试仍存在交叉依赖，过早拆包只会把相对 import
问题变成 package dependency 和循环依赖问题。

### 保留独立 endpoint daemon 与独立 DataService daemon

拒绝作为最终模型。两者需要协调同一 Pool、Catalog backend、SPDK runtime 和 publication
状态，会制造双重 ownership。迁移期兼容进程不改变最终单 node daemon 决策。

### 把所有 frontend 都放进 node daemon

拒绝。NFS-Ganesha 有独立 runtime/ABI，foreground FUSE 和 dufs 由显式命令拥有；它们与
managed SPDK endpoint 的进程约束不同。

## 迁移顺序约束

1. 已统一控制面命名：源码使用 `services/controller/`，Zig module 使用
   `zettide_controller`，安装产物使用 `zettide-controller`；`zettide-control` 只表示原仓库历史。
2. 已在[组件依赖与分层规则](../architecture/zh-CN/component-dependencies.md)记录依赖图，并已消除
   D1-D4 反向依赖。
3. 已建立独立 `zettide_storage` 与 `zettide_node` module root。
4. storage engine 已整体移动到 `libs/storage-engine/`，并提供独立 `zig build test`/`ci`。
5. 剩余产品代码已收敛到 `services/node/`，并只通过 public `zettide_storage` 依赖 engine。
6. 下一步迁移 consumers 与 compatibility facade；接通完整 DataService/node daemon 后，再迁移
   `zettide endpoint serve`。

不得用一次全目录移动跨过上述边界准备。

## 完成判据

该决策在以下条件满足时完成落地：

- `libs/storage-engine` 可以独立运行 portable unit tests；
- `services/node` 是 storage engine 的消费者，而非其 module root；
- 核心库不依赖 SPDK、endpoint、CLI 或 RPC；
- `zettide`、`zettide-node` 和 `zettide-controller` 的构建目标职责明确；
- DataService 与 managed endpoint 在一个 node owner 下 reconciliation；
- 兼容入口和 alias 均有明确删除条件；
- 全部非增量 test/check gate 通过。
