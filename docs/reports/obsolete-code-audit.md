# 过时代码与组件审计

- 状态：进行中（13 步中的前 2 步已完成）
- 基线 revision：`829b378`
- 范围：本仓库拥有的源码、build wiring、测试、automation 与安装产物
- 非范围：`vendor/` 固定依赖的内部死代码、`.zig-cache/`、`zig-out/`、`zig-pkg/` 和其他生成物

本文记录删除候选、证据和结论。它是维护审计报告，不改变当前产品 capability；涉及已接受
架构、持久格式或公开兼容面的删除仍需要对应 ADR 或迁移决策。

## 判定原则

“没有被普通源码 import”不足以证明可以删除。Zig lazy declaration、C/shell 独立编译、动态加载、
安装 header、automation profile 和格式 decoder 都可能不出现在单一 import graph 中。每个候选必须
同时检查以下证据：

| 证据 | 必查问题 |
| --- | --- |
| Production reachability | 是否从 executable/library/module root 或运行时 composition 可达？ |
| Build reachability | 是否由根 build、组件 build、CI、benchmark 或 shell compile command 构建？ |
| Test reachability | 是否只为 unit/integration/golden/cross-target gate 提供能力？ |
| Installed surface | 是否生成 executable、library、header、module、container 或配置样例？ |
| External compatibility | 是否属于 CLI、wire API、NFS C ABI、SPDK identity 或调用方约定？ |
| Persistent compatibility | 是否读取历史磁盘、WAL、snapshot、desired-state 或 command format？ |
| Architecture ownership | 是否被 Accepted ADR 或当前 Tier 范围明确保留？ |
| Replacement | 是否已有完成 parity、可独立验证且实际接线的替代实现？ |

删除必须以当前 build graph 和源码为准；文档中的“目标”不能单独证明代码仍有效，但 Accepted ADR
可以阻止在没有新决策时静默删除产品能力。

## 分类

### R0：可立即清理

同时满足：

1. 不进入 production、build、test、benchmark、automation 或安装产物；
2. 不承载持久格式、wire/ABI、CLI 或稳定 identity；
3. 不被 Accepted ADR 保留为当前或目标组件；
4. 没有动态加载、C symbol、shell path 或外部仓库 consumer 的证据；
5. 删除后不需要 compatibility shim。

典型对象是无消费者的 public re-export、重复 helper、废弃 test fixture 或已经被完整替代的私有文件。
R0 仍必须经过 focused gate 和根非增量 gate。

### R1：迁移后可删除

已有明确替代边界，但仍有有限消费者或 compatibility wiring。必须先：

1. 列出并迁移全部消费者；
2. 用显式 module/test root 取代 mega-facade 或隐式依赖；
3. 完成行为 parity；
4. 确认没有 persisted/wire/ABI 影响；
5. 在独立提交中删除旧入口。

### R2：需要产品或架构决策

代码未接线、与依赖版本不匹配、长期只在测试中存在，或者可能已经过时，但仍满足至少一项：

- 被 Accepted ADR/Tier completion criteria 明确保留；
- 对外协议或持久状态仍可出现该类型；
- 尚无具备 parity 的替代实现；
- 删除会缩减已声明产品能力。

R2 不能作为普通 dead-code cleanup 删除。结论只能是修复、正式 de-scope，或由新 ADR 取代旧决策。

### K：必须保留

当前 production/test/build 直接依赖，或者承担不可静默破坏的兼容责任。即使代码只处理旧版本，
只要受支持数据仍可能存在，也属于 K。

## 删除阻断条件

出现以下任一项时，候选默认不得删除：

- 改变 on-media magic、version、offset、checksum、reserved bits 或 reopen 行为；
- 删除 controller WAL/snapshot/command 的旧版本 reader；
- 删除 endpoint desired-state 的旧版本 reader；
- 改变现有 `zettide` CLI 参数、输出或退出行为；
- 改变 endpoint Unix wire API；
- 改变 `libzettide-nfs-backend.a`、header layout、状态值或 `zettide_nfs_*` symbols；
- 改变 NQN、NSID、IQN/LUN、vhost socket 或其他稳定 SPDK identity；
- 仅因为某能力尚未接入最终 daemon，就删除 Accepted ADR 明确要求的 Tier 能力。

若确需移除，必须先定义数据迁移、兼容读取、调用方迁移或 release break。

## 初始候选分组

以下是第 1 步的初始分类，不是最终删除结论；后续可达性和产品范围审计会补齐证据。

| 候选 | 初始分类 | 当前理由 | 进入下一分类前的条件 |
| --- | --- | --- | --- |
| `services/data-node/root.zig` legacy `zettide` facade | R1 | 只为现有 CLI 聚合 engine、FUSE、endpoint、SPDK；文档明确要求最终删除 | 迁移 `main.zig`、`cli/common.zig`、`cli/pool.zig` 的 3 个直接 imports；替换 compatibility test root |
| `services/data-node/v3/root.zig` | R1 | 当前作为 legacy facade 的 platform namespace；未发现 `zettide_data_node.v3` consumer | 先移除 legacy facade，并确认无 shell/外部 consumer |
| `zettide_data_node` 中无消费者的转发 export | R0/R1 | `storage`、`v3`、`data_service` 等可能扩大公开面而没有真实 consumer | 完整 public-symbol consumer audit；测试改用 private roots |
| `data_node_main.zig` / `data_node_service.zig` prototype | R2 | 未接入 executable build，只覆盖部分 DataService RPC，并拥有独立临时 state | 与目标 DataNodeContext 和完整 RPC surface 比较；决定立即接线还是删除 prototype |
| `endpoint_daemon.zig` 与 `zettide endpoint serve` | R1 | ADR 明确为迁移期 compatibility owner，但目前仍是唯一可运行 endpoint daemon | `zettide-data-node` 完成 endpoint/SPDK parity、restart、drain 和 compatibility 决策 |
| SPDK iSCSI adapter 与 automation | R2 | 当前源码引用 pinned SPDK 中未发现的 header/API，但 iSCSI 是 Accepted Tier 1 baseline | 验证依赖来源；选择修复 managed SPDK API 或新 ADR 正式 de-scope |
| controller reconciler/DataService client 等未运行时接线模块 | R2/K | 目前部分由 test/root 强制编译，且属于 Tier 2/3 基础 | 证明已被替代或由产品决策取消，不得仅按 runtime 未实例化删除 |
| v3/endpoint/controller legacy readers | K | 承担磁盘、desired-state、snapshot/WAL/command compatibility | 只能由独立格式迁移与兼容 ADR 处理 |
| FUSE、NFS、dufs、CSI、TxFS、NVMf、vhost | K/R2 | 有当前 gate、安装面或 Accepted 架构角色 | 仅在组件级产品 de-scope 后重新分类 |

## R0/R1 的最低删除证据

一个候选只有在报告中同时具备以下记录时才可进入删除提交：

- 全部静态和动态消费者清单；
- 构建、CI、automation 和安装面检查结果；
- replacement/parity 说明，或明确证明无需 replacement；
- compatibility 与持久格式结论；
- 删除前后 focused gate；
- `mise run test` 与 `mise run check` 非增量结果；
- 文档和源码映射更新。

## 组件可达性清单

### 调查方法与覆盖范围

第 2 步以 tracked files、所有 Zig build files、root CI workflow、mise task、CMake、Go package、
shell integration tests 和 Ansible automation 为入口进行静态调查：

- 本仓库拥有的 `services/` 与 `libs/` 源码共 189 个 `.zig`、`.c`、`.h`、`.go` 或 `.proto` 文件；
- 根 Zig build 当前公布 55 个 build steps；
- 对 Zig 相对 import 从 module、executable、library、test 和 benchmark roots 递归检查；
- 对 C source/header 另外检查 `addCSource*`、shell compiler command、CMake target 和 translate-C header；
- 对 Go 使用 package 规则检查，因为同 package 文件不需要显式文本 import；
- 对动态入口检查 CI、mise、shell 和 automation 中的路径引用。

该检查可以证明仓库内可达性，不能证明仓库外不存在 source-level consumer；公开 module、CLI、C ABI
和协议仍按兼容面处理。

### Build 与安装入口

| 入口 | Root/组合 | 默认根 build | 安装或公开表面 |
| --- | --- | --- | --- |
| Storage engine | `libs/storage-engine/src/root.zig` | 构建、测试 | `zettide_storage`、`libzettide-storage-engine` |
| CRC32C private module | `libs/storage-engine/src/crc32c.zig` | 作为 engine/data-node 依赖构建 | 非公开辅助 module |
| Legacy CLI | `services/data-node/main.zig` + `root.zig` | 构建、CLI 测试、cross compile | `zettide` executable |
| Data-node module | `services/data-node/data_node_root.zig` | `test-data-node`、module-root、benchmark/SPDK tests | `zettide_data_node` Zig module；没有 daemon artifact |
| NFS backend | `services/data-node/nfs_backend.zig` | Linux 构建及 Zig/C ABI tests | `libzettide-nfs-backend.a`、`zettide/nfs_backend.h` |
| Controller | `services/controller/src/root.zig`、`src/main.zig` | 构建、测试 | `libzettide-controller`、`zettide-controller` |
| DataService contracts | `libs/data-service-contracts/src/root.zig`、proto | controller dependency；组件本地有 `test` | `zettide_data_service_contracts` module、proto contract |
| TxFS | `libs/txfs/src/root.zig`、`tests/root.zig` | 构建、unit/integration tests | `libzettide-txfs` |
| Benchmarks | `benchmarks/*.zig`、两个 SPDK benchmark roots | 普通 benchmark sources 进入 `test-unit`；SPDK roots 条件构建 | 仅显式 `build-bench-*`/SPDK build step 安装 benchmark artifact |
| CSI | Go package `cmd/zettide-csi-node`、`internal/driver` | 不进入根 Zig build/CI | service-local `go test ./...` 和 Docker image |
| NFS FSAL | `services/nfs-fsal/CMakeLists.txt` | 不进入根 Zig build；NFS-Ganesha gate 依赖外部 configured tree | 动态 `FSAL_ZETTIDE` module，消费 NFS backend ABI |

默认根安装面包括 `zettide`、`zettide-controller`、storage-engine、controller、TxFS 与 Linux
NFS backend library artifacts，以及 Linux NFS header；不存在已安装的 `zettide-data-node`
executable。这是后续判断 compatibility facade 和 prototype 时的关键事实。

### 组件级可达性

| 组件 | Production 可达性 | Test/automation 可达性 | 当前结论 |
| --- | --- | --- | --- |
| Blob/Pool/Catalog engine | 由 `zettide_storage`、CLI、controller-independent consumers 使用 | engine、CLI、benchmark、SPDK、cross gates | K；主体不是删除候选 |
| Platform file/block adapters | CLI、NFS backend、benchmark 或 data-node module 使用 | Linux block、benchmark、SPDK storage gates | K |
| FUSE/dufs frontend | `zettide` CLI 命令直接使用 | CI FUSE、dufs、POSIX、SMB3 gates | K |
| Endpoint registry/control/daemon | `zettide endpoint serve` 直接使用 | endpoint unit 与 SPDK daemon lifecycle tests | R1；替代 daemon 就绪前仍为 production reachable |
| SPDK runtime/provider/NVMf/vhost | `-Dspdk=true` 条件接入 legacy CLI composition | link、endpoint、dispatcher、provider、storage、vhost 和 automation gates | K/R2；条件构建不等于 dead code |
| SPDK endpoint/dispatcher/NVMe C adapters | 不进入默认 CLI C source list | 由 focused shell tests、SPDK storage test 和 scheduled-Pool automation 显式编译 | Test/integration reachable，不是无引用代码 |
| SPDK iSCSI | `-Dspdk=true` source/link list 与 Catalog endpoint backend 可达 | iSCSI fio automation | R2；可达但与 pinned API 的兼容性需第 7 步判定 |
| Data Node prototype | 无 executable 或 build target | `data_node_service.zig` 仅由 lazy public declaration 指向；prototype tests 未形成可执行 gate | R2；详见文件异常 |
| Controller metadata/Raft runtime | `zettide-controller` executable 使用 | controller unit、integration、restart/failover tests | K |
| Controller reconciler | runtime 有可选 `data_service_client` composition，main 默认不注入 client | root/unit/runtime integration tests | R2/K；不是完全不可达，仅尚未形成默认产品 E2E |
| CSI Node service | 独立 Go executable/container | service-local Go tests、CSI automation profiles | K/R2；根 CI 缺口不等于不可达 |
| NFS backend + FSAL | backend 默认 Linux 安装；FSAL 由 Ganesha 动态加载 | ABI test、可选真实 RPC gate | K |
| TxFS | 独立安装 library | 根 TxFS unit/integration gate | K/R2；独立产品边界而非主 daemon dead code |

### 文件级异常

静态 root/import 检查在补入 package-local component roots 后，只发现一个没有任何 build root 的 Zig
entry：

| 文件 | 发现 | 分类影响 |
| --- | --- | --- |
| `services/data-node/data_node_main.zig` | 没有 root build、executable target、test target 或源码 consumer；只在文档中描述 | 强 R2 候选；必须在第 5 步决定接线或删除 |
| `services/data-node/data_node_service.zig` | 被 `data_node_root.zig` 的 lazy export 文本引用，但 data-node module 没有提供它要求的 `grpc_lite`、`data_node_proto`、`zettide_data_service_contracts` imports | 不是有效可消费的当前 module surface；与 main 一并决策 |
| CSI 的三个 Go files | 基于 basename 的初筛显示无文本引用，但它们由 Go package 规则隐式组合 | 假阳性，保留 |
| SPDK C adapters | 部分不在 `configureSpdk` product source list，但由 shell/automation compiler commands 构建 | 假阳性，不能按 Zig graph 删除 |

除上述 Data Node prototype 外，本轮没有发现第二个“无 build/package/dynamic 入口”的完整源码组件。
这不代表所有 public exports 都有消费者；第 4 步将继续以 symbol/export 粒度收窄
`zettide_data_node`。

### Gate 覆盖缺口

以下组件有明确入口，但没有进入根 `mise run test` 或根 GitHub portable job：

- `services/csi/` 只在 service-local mise 和 automation 中运行 Go tests；
- `services/nfs-fsal/` 依赖外部 NFS-Ganesha configured build，根 gate 默认不会构建 FSAL；
- data-service-contracts 有 package-local test，根图主要通过 controller dependency 使用它；
- SPDK product composition 仅在 `-Dspdk=true` 或 focused shell/automation gate 中构建；
- `data_node_main.zig` 没有任何 gate。

这些是验证覆盖问题，不自动转换成删除结论。后续步骤将在本文继续追加逐候选结论、删除批次和验证结果。
