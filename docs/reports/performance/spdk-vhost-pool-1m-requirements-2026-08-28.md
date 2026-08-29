# SPDK vhost scheduled Pool 1M IOPS 达成条件（性能防回归清单）

状态：固定 revision 和硬件 profile 的历史回归证据；不是通用产品要求或当前默认配置。

日期：2026-08-28

本文列出达到 ~1.08M IOPS（4 KiB 随机读，scheduled Pool vhost-user-blk，双 Optane
PCIe）所必需的全部条件。修改对应热路径时，"代码机制"一节中的任何一项被移除或改坏，
性能都会明显回退；每项附实测依据。验证方法见
`spdk-vhost-pool-1m-optimization-2026-08-28.md`。

## 达成条件总览

| 维度 | 条件 | 缺失后果（实测） |
|---|---|---|
| 硬件 | 双 Optane（0000:04:00.0/1 + 0000:03:00.0/1），Pool `0debd8728b1e58221d69e96189855647`（validate-only） | - |
| guest 规模 | 15 vCPU / 14 队列 / vCPU pin 到 vm-fc CPU 9-23 | 8 vCPU 上限 802K；16 vCPU 过订阅降到 898K |
| fio 深度 | outstanding ≥ 1024（`qd32-j32` 或 `qd128-j16`） | 512 outstanding 上限 ~961K |
| coalescing | 启用，delay_base 4-12us，iops_threshold 10000 | 关闭时 guest IRQ 成本压垮 8 vCPU |
| target 拓扑 | 2 reactor / 2 controller / 2 worker，concurrent groups 8，threaded 16，inline_batches 0 | 4 controller 实测 909K（更差） |
| 代码机制 | 见下节 7 项 | 各项回退幅度见下节 |

## 不可移除的代码机制（按实测影响排序）

### 1. SPDK vhost fixed-window coalescing（SPDK 子模块）

- 位置：SPDK 子模块（本仓 commit `c66b97b52` 修复的固定窗口实现），经
  `ZETTIDE_VHOST_COALESCING_DELAY_BASE_US` / `ZETTIDE_VHOST_COALESCING_IOPS_THRESHOLD`
  环境变量注入，ansible 变量
  `zettide_vhost_scheduled_pool_coalescing_delay_base_us` /
  `_coalescing_iops_threshold`（必须成对设置，否则断言拒绝）。
- 作用：把 guest 侧 virtio 中断压到 ~0.11 IRQ/IO，是 guest vCPU 效率的关键。
  8 vCPU 时单独价值 +3%（803K vs 780K）；15 vCPU 时 12us 与 6us 差别不大。
- re-org 注意：coalescing 延迟作用于完成路径，值过大会直接加延迟（12us 时
  2048 深度吞吐已不受影响，512 深度建议 ≤12us）。

### 2. Pool 异步批量读路径

- 位置：`libs/storage-engine/src/v3/pool_scheduled_data_device.zig`（`readBatchFirstAvailable` /
  `submitReadManyAtAsync`，上限 `max_read_count=32`）、`libs/storage-engine/src/v3/member.zig`
  （`submitReadMany`）、`libs/storage-engine/src/v3/pool_data_storage.zig`（`claimedSubmitReadDataMany`）、
  `services/data-node/spdk/storage.zig`（`submitReadManyAt`）。
- 作用：把 ~17-28 个 guest 请求聚成一组、再按成员盘拆成异步批下发。聚合是
  吞吐的结构性来源——实测"去掉分组节流"的实验（全异步直发）在所有深度
  回退 ~20%（已回滚，commit `0bd1f9f`）。
- re-org 注意：read policy `first_available` 是当前基准；不要在没有配对
  验证的情况下改批量上限或调度策略。

### 3. AsyncReadTask 回收池

- 位置：`services/data-node/spdk/storage.zig`（`task_pool` / `allocTask` / `freeTask`，
  容量 1024，自旋锁保护）。
- 作用：Zig 0.16 ReleaseSafe 下 `std.mem.Allocator` 的 create/free 会对整个
  对象做 0xAA 毒化 memset；回收池消除每批一次的 create/destroy，否则 memset
  占 target CPU ~16%（profile 实测）。
- re-org 注意：**任何热路径上的逐 IO/逐批 `allocator.create/destroy` 在
  ReleaseSafe 都有同样代价**，新增代码请复用对象或绕开 Allocator 包装。

### 4. worker 无锁队列 + 唤醒门控 + dispatch slot 预分配

- 位置：`tests/spdk_pool_data_nvmf_benchmark.zig`
  （`slots[2048]` SPMC 队列 + 序列号、`waiting` 标志 + seq_cst 协议、
  `DispatchSlot` 按指针传给 `std.Io.Group.concurrent`、`queue_capacity=2048`）。
- 作用：逐 IO `wake.set` 消除（futex 唤醒曾占 ~8%）；每组 1.9KB Task 分配
  消除（同样命中 ReleaseSafe 毒化）；队列深度 2048 是 qd128-j16
  （2048 outstanding）不触发 guest EIO 的前提（1024 时实测 queue full EIO）。
- re-org 注意：`queue_capacity` 低于 2048 时，2048 深度的 fio 会以
  `queue_full_rejects` 形式失败；lifecycle 断言要求该计数为 0。

### 5. provider 零拷贝直写（direct path）

- 位置：`services/data-node/spdk/bdev_provider.c`（`single_iov_buffer` 单 iov 直通）、
  `services/data-node/spdk/bdev_dispatcher.c`（DMA-capable 判定，失败才走 bounce memcpy）、
  `services/data-node/spdk/bdev_endpoint.c`。
- 作用：guest RAM 直接作为 NVMe DMA 目标，数据面零拷贝。实测
  `direct_batches` 占 99.99% 以上；bounce 一旦成为主路径，memcpy 会立刻
  成为热点（历史 profile 的 11-12% 即来源于此）。
- re-org 注意：`submitReadManyAt` 的 caller buffer 直传语义不能改成分段
  拷贝；iov 生命周期规则（回调返回前 caller 保有 buffer）不能破坏。

### 6. vhost 控制器/队列映射约束

- 位置：`tests/spdk-vhost-user-blk-fio.sh`（每控制器 `queues/controllers`
  条 virtqueue，`queue-size=256`）、`tests/spdk_pool_data_nvmf_args.zig`
  （`worker_count ≤ controller_count ≤ reactor_count`）。
- 作用：2 控制器 × 7 队列是当前甜点；每控制器队列数影响聚合与 reactor
  轮询成本。
- re-org 注意：queues 必须能被 controller 整除且 ≤ guest vCPU 数
  （ansible 断言）；reactor 掩码取进程 affinity 的前 N 个 CPU，target 进程的
  CPU 布局变化会改变 reactor 落点。

### 7. guest vCPU 拓扑与主机预算

- 位置：ansible 变量 `zettide_vhost_scheduled_pool_guest_vcpus` / `_queues` /
  `_vcpu_cpu_base`；QEMU `-smp` 与 vCPU 线程 taskset（脚本
  `qemu-vcpu-affinity` 逻辑）。
- 作用：vm-fc 共 24 vCPU，预算 ≈ guest 15 + target ~4.4 + QEMU/宿主机 ~2。
  16 vCPU 必然过订阅（实测 898K，且 p99 出现 42ms 抢占尾）。
- re-org 注意：target 侧新增常驻线程会直接吃掉 guest 预算；
  `zettide_vhost_scheduled_pool_target_cpu_list` 的 taskset 与 16 vCPU
  组合曾实测崩塌到 333K，使用该变量必须配对验证。

## 已测量的反模式（不要重新引入）

| 做法 | 实测结果 |
|---|---|
| guest 16 vCPU（vm-fc 24 vCPU 主机） | 898K，比 15 vCPU 慢 |
| target taskset 0-7 + guest 16 vCPU | 333K 崩塌（vCPU 抢占，p99 42ms） |
| inner guest `mitigations=off` | 958K ≈ 961K，无收益 |
| 全异步派发（worker 直发 + reactor 回调） | 全深度 -20%，已回滚（`0bd1f9f`） |
| guest 内 fio `--hipri=1` | virtio-blk 不支持 IOPOLL（EOPNOTSUPP） |
| guest 内 fio `sqthread_poll=1` | 174K（-84%），sqpoll 线程空转 |
| 4 控制器 / 4 worker / 12 队列 | 909K，比 2 控制器差 |

## 验收口径

- 基准 case：`randread-4k-qd32-j32`（或 `qd128-j16`），runtime 20s / ramp 5s。
- 达标：≥5 轮中位数 ≥ 1.04M IOPS，fio error=0，`queue_full_rejects=0`，
  `direct_batches` 占比 ≥ 99%，每轮结束双盘恢复 `nvme` 驱动。
- 原运行主机的参考变量文件：`/tmp/opencode/vm-fc-vhost-1m-vars.json`（不由仓库保存；相对基线
  vars 的增量：guest_vcpus=15、queues=14、vcpu_cpu_base=9、
  coalescing_delay_base_us=12、fio_case=randread-4k-qd32-j32）。
- 已知噪声带：±1.5%（共享 Proxmox 宿主机调度）；单次 ±3% 以内不算回归。
- 延迟代价：当前 1M 配置平均延迟 ~935us（深队列）；延迟敏感场景用
  `randread-4k-qd32-j16`（~961K / ~525us）。
