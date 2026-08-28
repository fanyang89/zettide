# CAWFS 共享 qcow2 接入

> 状态：目标契约；实现按本文顺序推进，当前不可用于生产数据

## 决策

qtr 的首条 CAWFS 接入路径是把 qcow2 保存到多个计算主机共同挂载的
CAWFS namespace。qtr 和 libvirt 继续使用普通文件路径；独立的 CAWFS 方向
提供 backend-neutral FUSE/POSIX frontend，以及共享 LUN 上的事务、对象、
extent 分配和条件发布。

该路径是既定/目标 managed Catalog Volume block publication route 之外的
shared-file profile，不替代后者，也不改变 block Volume 的 publication、Replica 或
snapshot 语义。它也不是当前 Blob-only Zettide 文件系统产品的 backend；
BlobFilesystem 和 CAWFS 不通过产品 backend selector 互换。

```text
qtr manifest: CAWFS volume ID + image ID
        |
        v
host-local path resolver
        |
        v
libvirt / QEMU qcow2 file
        |
        v
CAWFS backend-neutral FUSE/POSIX frontend
        |
        v
CAWFS filesystem model and transactional engine
        |
        v
whole shared SCSI LUN
```

qtr 不直接链接 CAWFS Zig API，不持有 extent handle，也不把 mount path 作为
持久身份。路径只是当前 host 上由稳定身份解析出的运行时状态。

## 身份域

以下身份彼此独立，不能由路径或进程号推导：

| 身份 | 作用域 | 要求 |
| --- | --- | --- |
| CAWFS volume ID | 一个已格式化共享 LUN | 格式化时生成，永不复用 |
| image ID | 一个 CAWFS namespace 内的 qcow2 | rename 后不变，不能使用 inode 路径替代 |
| VM disk ID | 一个 qtr VM manifest | 保留现有 guest-device identity |
| qtr host ID | 一个计算主机 | 重装前持久，不能使用 hostname 作为唯一权威 |
| host incarnation | qtr/FUSE host agent 的一次生命期 | 每次失去持久运行上下文后变化 |
| image owner epoch | 单个 image 的写入代次 | 每次 fenced takeover 严格增加 |
| operation ID | acquire/release/takeover 请求 | 响应丢失后以同一 ID 查询或重试 |

qtr 持久化 `(volume_id, image_id)`。mount point、canonical path、FUSE device、
QEMU PID 和 file descriptor 均为可重建 observation。

## Image Ownership

每个 writable qcow2 在 CAWFS 元数据树中保存一个权威 ownership record：

```text
image_id
vm_id
owner_host_id
owner_incarnation
owner_epoch
operation_id
state
```

首版状态为：

```text
FREE -> ACQUIRING -> OWNED -> RELEASING -> FREE
                     |
                     +-> FENCING -> OWNED at owner_epoch + 1
```

`ACQUIRING`、`RELEASING` 和 `FENCING` 是持久 intent，不是进程内锁。所有
状态变化通过 CAWFS transaction 条件发布。相同 operation ID 的重试必须返回
同一结果；不同 operation ID 不能静默接管未完成操作。

CAWFS mount 使用稳定 host ID 和 incarnation 打开。创建 writable file handle
和每次 mutable extent 写入都校验 ownership record。已打开的旧 file handle
不能因为 inode 仍存在而绕过 owner epoch。QEMU 文件锁作为额外冲突检测，不是
ownership authority。

## 启动与停止顺序

启动 writable VM disk：

1. qtr 在任何 libvirt 副作用前持久化 attachment/acquire intent 和 operation ID。
2. 确认目标 CAWFS volume 已挂载、volume ID 匹配且 mount recovery 完成。
3. 以 `(image_id, vm_id, host_id, incarnation)` 获取 ownership。
4. FUSE 返回能够执行 QEMU 所需 lock 和 direct-I/O profile 的 resolved path。
5. qtr 生成 libvirt file disk XML 并启动 VM。
6. qtr 持久化 libvirt observation；响应丢失时观察 owner 和 domain 状态后收敛。

clean stop/release：

1. qtr 先持久化 releasing intent。
2. 请求 guest shutdown 或显式 destroy，并确认 domain 已 inactive。
3. 确认 QEMU 已关闭 qcow2 writable handle。
4. FUSE/CAWFS drain 该 image 的 accepted I/O，并完成 durability barrier。
5. ownership 由 `RELEASING` 条件发布为 `FREE`。
6. qtr 清理 attachment intent。

qtr 进程退出不等于 QEMU 退出。qtr crash、API timeout、libvirt 连接丢失或
heartbeat TTL 过期都不能自动释放 ownership。

## Fenced Takeover

非 clean takeover 必须在增加 owner epoch 前取得下列至少一种外部证据：

- 旧 host 已完成受信任的 power fence；
- SAN 已撤销旧 host 对整个 CAWFS LUN 的访问，并确认旧路径和在途 I/O 已 drain；
- 未来经过独立认证的 watchdog/fencing provider 给出等价证明。

CAWFS voting majority、qtr heartbeat、QEMU lock 丢失和“旧 mount 当前不可达”都
不能证明旧写入已经停止。旧 host 失联且无法取得 fencing evidence 时，image
保持不可用。

fenced takeover 顺序：

1. 持久化 `FENCING` intent、目标 host、operation ID 和所需的新 epoch。
2. 执行并持久化外部 fencing evidence。
3. 等待旧 LUN access 和已接受 I/O drain。
4. CAWFS 恢复 indeterminate metadata/data operations，冻结无法解析的 owner/range。
5. 条件发布更高 owner epoch 和新 host/incarnation。
6. 新 mount 获得该 epoch 后才允许 writable open 和数据写入。

LUN access revoke 是 host 级 fence，会同时中断该 host 对同一 CAWFS volume 上
其他 image 的访问。qtr 必须把这些 VM 标记为需要 reconciliation，不能把单个
image takeover 描述为无影响的局部动作。

## QEMU 文件语义 Profile

首版 CAWFS POSIX backend 必须覆盖 qtr、`qemu-img` 和 QEMU 实际使用的操作：

- 普通文件和目录 metadata、稳定 inode identity、权限和时间戳；
- create、exclusive create、open、close、pread、pwrite；
- sparse hole read、extend、truncate、fallocate 和空间回收；
- fsync、fdatasync、flush，以及成功后 crash durability；
- atomic rename、unlink、hard link 和 open-but-unlinked handle；
- cross-mount advisory/OFD lock 的冲突检测；
- statfs 和明确的 ENOSPC；
- aligned direct I/O，且不得由不一致的 host page cache 提供共享写语义。

managed image 的 staging/hard-link publication 在该 profile 通过前不能直接复用。
若 hard link 不满足 atomic no-replace 语义，qtr backend 必须改用 CAWFS 原生的
条件 publication，而不是退化为覆盖 rename。

共享 image source 只接受资格测试通过的 libvirt cache/I/O 组合。初始候选为
`cache=none` 加 native/direct I/O；若 FUSE、kernel 或 QEMU 不支持该组合，必须
先通过故障和 durability 测试冻结替代 profile，不能静默回退到 writeback cache。

## 权限与部署

每个 qtr host 运行一个受管 CAWFS mount service：

- service 以完整 SCSI LUN 打开设备，拒绝 partition、sliced mapper 和 geometry mismatch；
- mount recovery、allocator recovery 和 ownership validation 完成后才报告 ready；
- qtr service 在 mount ready 之后启动，在 mount lost 后停止新的 VM start；
- mount point 通过固定 qemu group 和 `allow_other` policy 授权，不依赖递归修改共享文件 ACL；
- SELinux policy、device permission 和 service ordering 属于生产准入测试。

同一 host 不得通过两个独立 CAWFS mount 实例以不同 incarnation 同时写同一
volume。mount service 必须使用 host-local singleton lock 防止重复实例；该锁不
替代跨 host ownership。

## Indeterminate 与恢复

普通 mutable write dispatch 后失败可能晚到并覆盖后继写。相关 image/range 必须
冻结，直到原操作被解析或旧 host/LUN 被 fence 并 drain。禁止在同一 range 上盲目
重发 ordinary write，也禁止提前复用 extent。

重启后的收敛顺序固定为：

1. 验证 volume headers、whole-LUN geometry 和 transport capability。
2. 恢复 claim gates、allocator 和 pending metadata operations。
3. 打开并验证当前 anchor 和 filesystem root。
4. 恢复 image ownership records 与本地 writable handles observation。
5. qtr 对比 attachment intent、CAWFS owner、resolved path 和 libvirt domain。
6. 只有 owner 与本 host/incarnation/epoch 完全匹配时才恢复 writable service。

无法证明成功或失败的 operation 保持 pending；恢复代码不得创建第二个 owner、
第二个 image 或第二个 writable QEMU attachment。

## 实施顺序

1. 完成 CAWFS SCSI-backed immutable object store 和统一 block-device fault model。
2. 在独立 CAWFS 方向定义 backend-neutral filesystem interface。
3. 实现 CAWFS inode、directory、file extent map、ownership 和 POSIX transaction。
4. 实现 CAWFS FUSE/POSIX adapter 和受管 mount service，不接入 Zettide BlobFilesystem 产品的 backend selector。
5. 通过 `qemu-img` 和真实 QEMU 的 cache、lock、sparse、flush、crash 资格测试。
6. qtr 增加稳定 CAWFS image source、持久 attachment intent 和 start/stop reconciliation。
7. 接入显式 fencing provider，完成双 host shared-LUN E2E。

每个阶段必须保持以下门禁通过：

```text
mise run check:zettide-cawfs
mise run check:zettide
mise run check:qtr
```

硬件准入另需 dedicated shared LUN，覆盖 path loss、delayed I/O、host power fence、
LUN revoke、mount crash、qtr crash 和旧 host 恢复。

## 首版非目标

- 自动选择替代计算 host 或自动重启 VM；
- qcow2 backing-chain、snapshot、commit、rebase 和跨 image consistency group；
- 用 block `VolumeSnapshot` 代替 qcow2 或 CAWFS filesystem snapshot；
- 仅依赖 QEMU lock、heartbeat TTL 或 CAWFS voting 完成 takeover；
- 允许同一个 qcow2 同时存在两个 writable QEMU process；
- 把现有 Catalog Volume block publication route 改写为 CAWFS 文件路径。
