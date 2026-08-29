# 存储抽象与持久格式归属

> 状态：`libs/storage-engine/` package 与 module/build 边界已落地；表中更细的 foundation 内部分层仍是后续优化

本文细化[组件依赖与分层规则](component-dependencies.md)中的 L0-L1，并明确持久格式
应随哪个领域迁移。它不是新格式规范；磁盘字节仍由现有 codec、golden fixture 和
`docs/v3-*.md` 定义。

## 结论

1. `v3/storage.zig` 中的 backend-neutral I/O contract 属于 `libs/storage-engine` foundation。
2. file、Linux io_uring、raw block 和 SPDK 是该 contract 的实现，不属于 portable engine root。
3. 不创建独立 `libs/formats`。持久格式是所属领域的兼容 API：Pool/Member/Catalog format
   随 Pool 领域迁移，Blob/BlobFilesystem format 随 Blob 领域迁移。
4. 只有跨领域复用的 checksum、integer/region codec 和 storage contract 放在 shared foundation。
5. `size.zig` 是 CLI 文本解析，不是持久格式或存储抽象。
6. 本文不修改 magic、version、offset、checksum、digest、reserved-zero 或 feature policy。

## Storage 文件归属

| 当前文件 | 当前职责 | 后续内部归属 | 后续动作 |
| --- | --- | --- | --- |
| `libs/storage-engine/src/v3/storage.zig` | owned random-access Storage、file/custom backend、batch/async I/O、transport diagnostics | 拆出 contract 到 `libs/storage-engine/src/foundation/storage.zig` | 将内建 file 实现和平台名称从核心 contract 分离 |
| `libs/storage-engine/src/v3/storage_window.zig` | 对 borrowed Storage 建立有界逻辑 window | `libs/storage-engine/src/foundation/storage_window.zig` | 保留 generic decorator；单独测试越界、identity 和 close ownership |
| `services/node/v3/file_storage.zig` | `auto/posix/io_uring` mode 解析、Linux fallback 和 adapter 选择 | CLI/node platform composition | 不进入 portable root；mode parsing 属于产品配置 |
| `services/node/v3/linux_file_storage.zig` | regular file 的 io_uring Storage adapter | Linux platform adapter | 继续实现 foundation Storage port |
| `services/node/v3/linux_raw_storage.zig` | raw block io_uring、iopoll、async lane 和 telemetry | Linux platform adapter | 与 core contract 解耦平台 enum；保留 durable sync/error semantics |
| `services/node/v3/linux_block_device.zig` | ioctl/sysfs eligibility、exclusive open 和 raw Storage composition | Linux node/tool adapter | device safety policy 留在平台层，不进入 engine foundation |
| `services/node/linux_io_uring.zig` | Linux io_uring engine | Linux platform adapter | 只由 Linux storage/frontend adapter 引用 |
| `services/node/spdk/storage.zig` | SPDK bdev Storage adapter | `services/node` SPDK adapter | 见 [SPDK Backend 与 Export 归属](spdk-adapter-export-map.md)，不进入 storage-engine |

### Storage contract 保留项

以下语义是 engine 所需的 backend-neutral contract，可以保留在 foundation：

- capacity 和 minimum I/O size；
- owned close lifecycle；
- stable `sameIdentity` 比较；
- positional read/write；
- batch read/write；
- `syncData` 与完整 `sync` 的显式 durability barrier；
- 可选 async batch submission，前提是 completion 不暴露平台类型。

### Storage contract 拆分项

当前 `storage.zig` 同时拥有 contract、file backend 和 diagnostics。迁移前拆分：

| 当前 API | 问题 | 目标 |
| --- | --- | --- |
| `Storage.createFile/openFile/initOwned` | port 自己创建具体 file backend | 移到显式 POSIX/std.Io file adapter；engine 只接收 Storage |
| `Kind.spdk_bdev` | core enum 暴露具体第三方实现 | 改为稳定介质/能力描述，或由 adapter-local diagnostics 保存 |
| `TransportKind.posix/io_uring/custom` | correctness contract 暴露实现名称 | 从核心 correctness API 移到可选 diagnostics/telemetry port |
| `TransportStats` | benchmark telemetry 与 I/O contract 绑定 | 保持可选扩展，但不让 engine 依据统计字段改变正确性 |
| custom vtable context | 同时承担 ownership 和 implementation dispatch | 保留 type erasure，但明确成功 init 后 context 由 Storage close 消费 |

不得为了拆分而弱化当前 sync、partial-read、alignment、queue-full 或 close-on-error 语义。

## Shared foundation 文件归属

| 当前文件 | 首轮目标归属 | 说明 |
| --- | --- | --- |
| `libs/storage-engine/src/crc32c.zig` | storage-engine checksum dependency module | 是格式算法 adapter；构建只向需要 CRC32C 的 format module 注入 `crc32c` |
| `libs/storage-engine/src/v3/codec.zig` | `libs/storage-engine/src/foundation/codec.zig` | little-endian integer、CRC32C、BLAKE3、Region 和 checked alignment |

`crc32c.zig` 包装外部 C/C++ 实现，不等于平台 frontend。它可以作为 storage-engine 的显式
算法依赖，但不得再因为一个 mega-module 而注入 CLI、endpoint 或 SPDK-only target。

## Pool/Member/Catalog 持久格式

这些文件属于 storage engine，但不属于 shared foundation；它们随 Pool/Member/Catalog
领域迁移，详细拆分见 [Pool、Member 与 Catalog 归属](pool-member-catalog-map.md)：

| 格式族 | 当前文件 | 归属规则 |
| --- | --- | --- |
| Member header/features/data mode | `v3/member_format.zig` | Pool/Member format；继续拥有 feature policy 和 PoolDataMode wire 值 |
| Legacy fixed topology/layout/genesis | `v3/topology.zig`、`v3/layout.zig`、`v3/genesis_payload.zig` | Pool format compatibility；不得因新动态格式删除旧 decoder/tests |
| Dynamic topology/layout/genesis | `v3/pool_topology.zig`、`v3/pool_layout.zig`、`v3/pool_genesis_payload.zig` | Pool format；依赖 shared codec 和 pool policy |
| Control envelope/certificate | `v3/control_record.zig` | Pool control format；不依赖 journal runtime 或 SPDK |
| Member bootstrap payload | `v3/member_bootstrap.zig` | Pool control payload format；随 Member/Pool 领域 |
| Membership payload | `v3/membership.zig` | Pool membership format；随 Pool 领域 |
| Authority/evidence/checkpoint | `v3/pool_evidence.zig`、`v3/pool_certificate.zig`、`v3/pool_authority_checkpoint.zig` | Pool authority format/value；runtime selection 仍在 Pool 领域 |
| Catalog legacy header | `v3/catalog_volume_header.zig` | Catalog format compatibility |
| Catalog pages/graph/mutation | `v3/pool_catalog.zig`、`v3/pool_catalog_page.zig`、`v3/pool_catalog_graph.zig`、`v3/pool_catalog_mutation.zig` | Catalog domain format；在 Pool/Member/Catalog 步骤确认细分 |

格式文件可以引用同领域的 persisted value type，但不能 import journal coordinator、endpoint、
SPDK worker 或产品 CLI。构造函数可以接受 caller 提供的 ID/time/randomness；encode/decode/
validate 必须保持确定且无外部副作用。

## Blob/BlobFilesystem 持久格式

这些文件随 BlobFilesystem 领域迁移，不下沉到通用 Pool foundation；详细拆分见
[Blob 与 BlobFilesystem 归属](blob-filesystem-map.md)：

| 当前文件 | 目标领域 | 原因 |
| --- | --- | --- |
| `blob_format.zig` | Blob store format | 定义 Blob header、arena geometry、BlobRef 和 payload checksum |
| `blob_object_format.zig` | Blob object format | 绑定 Blob map page reference 和 object head |
| `blob_filesystem_format.zig` | BlobFilesystem format | 绑定 inode/dentry/orphan/reservation、metadata、name profile 和 file snapshot |
| `metadata.zig` | BlobFilesystem persisted value | POSIX-like metadata wire format 及 relatime 语义 |
| `name_profile.zig` | BlobFilesystem namespace semantics | persisted profile ID/version 和 portable-v1 Unicode normalization |

`name_profile.zig` 的 utf8proc 是格式/namespace 算法依赖，不是 OS adapter。构建必须继续固定
Unicode 和 utf8proc version，不能用 host locale 或平台默认 normalization 替代。

`blob_filesystem_format.zig` 依赖 `blob_file`、`blob_map`、`metadata` 和 `name_profile`，说明它是
BlobFilesystem 领域格式，而不是可以独立发布的通用 codec package。

## 不属于本区域

| 当前文件/区域 | 后续步骤 |
| --- | --- |
| `size.zig` | CLI 与 DataService；仅解析用户输入 |
| `v3/linux_pool_plan.zig` | Pool/CLI composition；包含设备计划和 Blob name-profile 输入 |
| `blob_map.zig`、`blob_file.zig`、`blob_store.zig` 等 runtime | BlobFilesystem 区域 |
| `v3/member.zig`、`journal.zig`、`pool_member_set.zig` 等 runtime | Pool/Member/Catalog 区域 |
| FUSE/NFS/dufs | frontend 区域 |
| endpoint registry/control/daemon | endpoint 区域 |
| SPDK C/Zig wrappers | SPDK 区域 |

## 跨领域 geometry 处理

原有 `pool -> blob_format` 反向依赖已经通过 `data_mode_geometry.zig` 解除。当前规则：

1. Member header 继续持久化 Pool data mode 和 feature bits；
2. Pool foundation 只计算 Member/control/metadata/data region，不解释 BlobFilesystem；
3. shared data-mode geometry 提供创建阶段所需的最小容量与 alignment contract；
4. Blob/Catalog 层分别解释自己的 data format，Pool production path 不 import Blob format；
5. CLI/node 组合 Pool geometry、设备安全检查与所选 data-mode requirements。

后续调整 symbol 或内部布局不得重新建立 `Pool -> BlobFilesystem` production dependency。

## 建议目标布局

```text
libs/storage-engine/src/
  root.zig
  foundation/
    codec.zig
    storage.zig
    storage_window.zig
  pool/
    format/
    ...
  catalog/
    format/
    ...
  blob/
    format/
    ...
  filesystem/
    metadata.zig
    name_profile.zig
    ...

services/node/src/platform/linux/
  file_storage.zig
  raw_storage.zig
  block_device.zig
  io_uring.zig

services/node/src/platform/spdk/
  storage.zig
```

最终是否把 Linux adapter 共享给 `zettide` CLI，由 build composition 决定；不能为了复用而
把它重新导出为 storage-engine portable root 的隐式能力。

## 格式迁移不变量

文件移动和 module 拆分必须保持：

- 所有 magic、major/minor version、encoded size 和字段 offset；
- little-endian encoding；
- CRC32C/BLAKE3 domain 和 checksum offset；
- reserved-zero、feature compatibility 和 canonical ordering 校验；
- A/B header 选择、sequence 和 authority 规则；
- golden fixture 字节及 corruption tests；
- legacy format decoder 和 reopen compatibility；
- name-profile persisted ID/version 及 pinned Unicode behavior。

纯移动不得顺便升级格式。任何格式变化必须独立设计 version、旧数据读取策略和 migration
测试。

## 实施状态

package 移动与独立 `zettide_storage` root 已完成；`test-storage-engine` 递归引用 engine test
namespaces，`test-module-roots` 验证 platform/product exports 不进入 engine。以下前三项是 package
内部继续收窄 contract 的后续工作，不阻塞当前 package 边界：

- [ ] 从 `storage.zig` 提取 file backend；
- [ ] 将 SPDK/io_uring 名称移出 engine correctness contract；
- [ ] 为 `storage_window.zig` 建立独立 portable test root；
- [x] 将 CRC32C 和 utf8proc 只注入需要它们的 module；
- [x] 为 Pool data mode 提取 geometry composition contract；
- [x] 确认格式 golden/corruption/reopen tests 在新 module root 下仍全部编译；
- [x] 确认 Windows/macOS portable build 不引用 Linux/SPDK adapter。

## 验证边界

当前 package/module 边界落地时没有修改 magic、version、offset、checksum 或格式 policy。
后续边界修改必须继续通过 library-local `zig build ci`、根 `test-storage-engine`、`test-unit`、
`test-cross`，以及仓库非增量 `mise run test` 和 `mise run check`。
