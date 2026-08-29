# Zettide 文档

本目录只维护 Zettide storage repository 拥有的架构、接口、格式、运行与验证文档。
`qtr` 和 `etz` 是独立项目；本文档可以描述它们与存储系统的集成边界，但不维护其实现状态、
构建命令或源码映射。`vendor/` 下的文档属于固定版本的第三方依赖，不纳入本目录的规范层级。

## 规范层级

发生冲突时按以下顺序处理：

1. [`decisions/`](decisions/README.md) 中状态为 **Accepted** 的 ADR 决定已经冻结的架构约束。
   只有新的 ADR 可以取代这些约束。
2. [`architecture/zh-CN/`](architecture/zh-CN/README.md) 描述系统架构、目标能力和组件边界；
   它必须符合已接受 ADR。
3. [`architecture/zh-CN/00-scope-and-status.md`](architecture/zh-CN/00-scope-and-status.md)
   是当前实现成熟度的唯一汇总页。源码、协议和测试用于核实“当前/部分/目标”状态，但不能
   静默改变已接受的架构决策。
4. 格式、语义和兼容性规范约束对应实现；发现偏差时必须判断是实现缺陷、文档状态过期，
   还是需要新的兼容性决策。
5. 报告与历史记录只保存证据和溯源，不定义当前产品能力。

## 文档分类

### 架构与决策

- [存储架构](architecture/zh-CN/README.md)：系统边界、数据模型、控制面、数据面与路线图。
- [架构决策](decisions/README.md)：已经接受的仓库级边界和不变量。

### 持久格式与语义

- [v3 Member 与 Pool 格式](v3-format.md)
- [v3 multi-Volume Catalog 格式](v3-multivolume-format.md)
- [v3 control rollover 格式](v3-control-rollover-format.md)
- [文件系统语义](fs-semantics.md)
- [跨平台名称规范](portable-name-profile.md)

格式文档中的 `current` 表示已有编码器、解码器或 reopen 路径；仅有 schema、预留字段或未来
布局说明不能证明产品 lifecycle 已实现。

### 验证与运行 profile

- [POSIX profile](posix-profile.md)
- [POSIX nightly](posix-nightly.md)
- [SMB3 profile](smb3-profile.md)

组件自身的运行与构建说明位于对应目录的 `README.md`，包括
`libs/storage-engine/`、`services/node/`、`services/controller/`、`services/csi/`、
`services/nfs-fsal/` 和 `libs/txfs/`。

### 报告与历史

- [`reports/`](reports/README.md)：带固定环境、revision 和限制条件的测量报告；报告不是当前 capability 声明。
- [`history/`](history/README.md)：已经完成的仓库迁移和其他溯源记录；历史步骤不是待执行计划。

## 状态词

| 状态 | 含义 |
| --- | --- |
| 当前 | 仓库内存在产品或组件实现，并有对应构建或测试入口 |
| 部分 | 已有局部实现或专项 gate，但缺少声明能力所需的完整 lifecycle、故障语义或端到端准入 |
| 目标 | 已由架构选择但尚无足够实现证据 |
| 非目标 | 当前架构明确不处理 |
| 历史 | 只用于溯源，不应作为当前操作步骤或能力说明 |

新增文档必须明确归入上述类别。临时实施计划不得长期留在规范目录；计划完成、阻塞条件失效
或源码基线漂移后，应删除或转为明确标记的历史记录。
