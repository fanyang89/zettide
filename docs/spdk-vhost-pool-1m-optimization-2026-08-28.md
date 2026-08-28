# SPDK vhost scheduled Pool 1M IOPS 优化报告

日期：2026-08-28

## 摘要

在 `spdk-vhost-pool-baseline-2026-08-28.md` 基线（802K IOPS）之上，通过 profile 归因、
三处 target 代码优化和配置空间扫描，scheduled Pool vhost-user-blk 4 KiB 随机读达到
**1,084,574 IOPS**，相对基线 +35.2%，达到 native SPDK 上限（1,174,627 IOPS）的 92.3%。

最终配置连续五轮验证全部超过 1M IOPS：中位数 1,084,145，均值 1,081,489，
离散幅度 2.63%，fio 错误均为 0，provider `queue_full_rejects=0`，双盘每轮均恢复
Linux `nvme` 驱动。

## 归因结论（Phase 0）

对基线配置采集 perf（call-graph fp）与 gperftools CPU profile，结论：

1. **memset（target CPU 的 16.34%）不是数据拷贝**。Zig 0.16 `std.mem.Allocator` 在
   ReleaseSafe 下对 create/free 执行 `@memset(bytes, undefined)` 毒化填充。热路径上
   两处高频分配为此付出代价：
   - `std.Io.Group.concurrent` 每组按值拷贝整个 ReadGroup（约 1.9 KB）分配 Task，
     alloc/free 各毒化一次；
   - SPDK 存储层 `submitReadManyAt` 每个异步批 `create/destroy` 一个
     `AsyncReadTask`（约 800 B），同样双侧毒化。
2. **futex 唤醒（约 8%）**：worker 无锁队列的 `submit()` 对每条 IO 无条件
   `wake.set()`，稳态下约 80 万次/秒的事件触发。
3. **memcpy 在 PCIe 路径可忽略（self 0.10%）**。`pool_async_metrics` 证实
   `direct_batches` 占 99.99% 以上，guest RAM 直接 DMA，bounce 路径基本不触发。
   此前 "memcpy 11-12%" 的印象来自 synthetic 传输 profile，不适用于 PCIe 数据面。
4. **瓶颈始终在 guest vCPU 容量**：基线 8 vCPU 已饱和（7.89 核）。

## 代码改动

zettide 子模块，基线 `9e10eae` 之上：

| commit | 内容 |
|---|---|
| `4c70108` | 新增 fio case `randread-4k-qd16-j32` 与 `randread-4k-qd32-j32` |
| `59c3466` | `AsyncReadTask` 按 endpoint 回收池，消除每批 create/destroy 毒化与 malloc/free |
| `38c96a3` | worker 唤醒门控（仅 worker 阻塞时 `wake.set`）；dispatch slot 预分配按指针派发，消除每组 1.9 KB Task 分配 |
| `0b6abdb` | 新增 `zettide_vhost_scheduled_pool_target_cpu_list`（target 进程 taskset） |
| `e1ac277` | 新增 `zettide_vhost_scheduled_pool_guest_mitigations_off`（inner guest 关缓解） |
| `e6a9eab` | mitigations 重启时不再 `-no-reboot`，保持 QEMU 存活 |

代码改动的直接效果（8 vCPU 基线配置对照）：target CPU 从 4.78 核降到 4.5 核
（-6%）；IOPS 单轮 777,853 与基线 802,346 处于同一噪声带。代码优化主要意义是
移除已证实的热路径开销，吞吐提升主要来自配置。

## 配置扫描（单轮筛选）

公共条件：双 Optane PCIe validate-only Pool、2 reactor、2 worker、concurrent groups 8、
threaded 16、inline_batches 0、coalescing threshold 10000、runtime 20 s / ramp 5 s。

| 轮 | guest | fio case | coalescing | 其他 | IOPS | 结论 |
|---|---|---|---|---|---:|---|
| 基线复测 | 8 vCPU / 8 q | qd32-j16 | 4 us | - | 802,346 | 参照 |
| R1 | 8 vCPU / 8 q | qd32-j16 | 4 us | 代码优化 | 777,853 | 噪声带内 |
| R2 | 16 vCPU / 16 q | qd16-j32 | 4 us | target taskset 0-7 | 332,848 | 崩塌：24 vCPU 全占用，p99 42 ms，vCPU 抢占 |
| R3 | 12 vCPU / 12 q | qd32-j16 | 4 us | - | 933,673 | guest 11.2 核仍饱和 |
| R4 | 14 vCPU / 14 q | qd32-j16 | 8 us | - | 957,232 | 边际收益递减 |
| R5 | 15 vCPU / 14 q | qd32-j16 | 12 us | - | 960,634 | guest IRQ/IO 降到 0.11 |
| R6 | 16 vCPU / 16 q | qd16-j32 | 12 us | 无 taskset | 897,792 | 16 vCPU 过订阅，不崩但更慢 |
| R7 | 15 vCPU / 14 q | qd32-j16 | 12 us | guest mitigations=off | 958,118 | 无收益（缓解非 guest 成本主因） |
| R8 | 15 vCPU / 14 q | **qd32-j32** | 12 us | - | **1,084,574** | 破 1M |

扫描结论：

1. **outstanding 深度是最后的闸门**。R5（512 outstanding）均值延迟 525 us，
   对应吞吐上限约 975K；qd32-j32 把 outstanding 提到 1024 后吞吐跳到 1.08M，
   代价是均值延迟升至 935 us（设备队列排队，native 同深度亦如此）。
2. **guest 效率随 vCPU 数递减**：8→15 vCPU 时 guest core-s/百万 IO 从 10.1 升到
   14.0；16 vCPU 在 vm-fc（24 vCPU）上必然过订阅。15 vCPU 是该主机的甜点。
3. **target taskset 与 16 vCPU 的组合是灾难**（R2）；taskset 本身保留为可用变量，
   但未进入最终配置。
4. inner guest `mitigations=off` 已验证生效（spectre_v2: Vulnerable）但无吞吐收益，
   不进入最终配置。

## 最终配置五轮验证

配置（`/tmp/opencode/vm-fc-vhost-1m-vars.json` 相对基线 vars 的增量）：

```json
{
  "zettide_vhost_scheduled_pool_guest_vcpus": 15,
  "zettide_vhost_scheduled_pool_queues": 14,
  "zettide_vhost_scheduled_pool_vcpu_cpu_base": 9,
  "zettide_vhost_scheduled_pool_coalescing_delay_base_us": 12,
  "zettide_vhost_scheduled_pool_fio_case": "randread-4k-qd32-j32"
}
```

| 轮 | IOPS | 平均延迟 | p99 | fio error |
|---|---:|---:|---:|---:|
| R8（扫描） | 1,084,574 | 935 us | 1.729 ms | 0 |
| V1 | 1,085,297 | 936 us | 1.909 ms | 0 |
| V2 | 1,064,667 | 951 us | 1.925 ms | 0 |
| V3 | 1,093,106 | 927 us | 1.696 ms | 0 |
| V4 | 1,082,232 | 936 us | 1.712 ms | 0 |
| V5 | 1,084,145 | 935 us | 1.860 ms | 0 |

六个样本：中位数 **1,084,145**，均值 1,081,489，最小 1,064,667，
离散幅度（(max-min)/mean）2.63%，全部 ≥ 1M。

## CPU 效率（第 V5 轮）

| 路径 | target 核 | QEMU/guest 核 | target core-s/百万 IO | guest core-s/百万 IO | 合计 |
|---|---:|---:|---:|---:|---:|
| 基线 802K | 4.78 | 7.89 | 6.12 | 10.11 | 16.24 |
| 最终 1.08M | 3.82 | 13.68 | 3.53 | 12.62 | 16.15 |

总 CPU/IO 与基线持平（16.15 vs 16.24），但结构改变：target 侧每 IO 成本下降 42%
（代码优化 + 每批请求数从约 12 升到约 28），腾出的预算全部交给 guest vCPU。

## 限制与后续方向

- 吞吐提升依赖更深的 outstanding（1024），平均延迟从 626 us 升至 935 us；
  延迟敏感场景应继续使用 R5 配置（961K / 525 us）。
- guest core-s/百万 IO 随 vCPU 数上升（10.1→14.0），guest 内串行开销
  （virtio 提交路径、嵌套 VM-exit）是下一道墙；进一步提频需要 guest 内
  per-IO 成本剖析（guest 侧 perf）。
- 16 vCPU 与 target taskset 的失败组合（R2）未做根因定位，仅确认与
  CPU 过订阅相关。
- 代码优化的独立收益（约 6% target CPU）淹没在单轮噪声中，未做五轮配对验证；
  其正确性由六轮 lifecycle 全绿（`test_succeeded=true`、`cleanup_rc=0`）和
  `queue_full=0`、`direct_batches≈100%` 佐证。

## 归档索引

| 轮 | 归档 |
|---|---|
| 基线复测（perf） | `test-results/ansible/vm-fc-20260828T140807-9e10eae489cc.tar.gz` |
| 基线复测（gperftools） | `test-results/ansible/vm-fc-20260828T141326-9e10eae489cc.tar.gz` |
| R1 | `test-results/ansible/vm-fc-20260828T143536-0b6abdbac209.tar.gz` |
| R2 | `test-results/ansible/vm-fc-20260828T144023-0b6abdbac209.tar.gz` |
| R3 | `test-results/ansible/vm-fc-20260828T145030-0b6abdbac209.tar.gz` |
| R4 | `test-results/ansible/vm-fc-20260828T145523-0b6abdbac209.tar.gz` |
| R5 | `test-results/ansible/vm-fc-20260828T150452-0b6abdbac209.tar.gz` |
| R6 | `test-results/ansible/vm-fc-20260828T151058-0b6abdbac209.tar.gz` |
| R7 | `test-results/ansible/vm-fc-20260828T152121-e6a9eab041f7.tar.gz` |
| R8 | `test-results/ansible/vm-fc-20260828T152656-e6a9eab041f7.tar.gz` |
| V1 | `test-results/ansible/vm-fc-20260828T153217-e6a9eab041f7.tar.gz` |
| V2 | `test-results/ansible/vm-fc-20260828T153609-e6a9eab041f7.tar.gz` |
| V3 | `test-results/ansible/vm-fc-20260828T154001-e6a9eab041f7.tar.gz` |
| V4 | `test-results/ansible/vm-fc-20260828T154408-e6a9eab041f7.tar.gz` |
| V5 | `test-results/ansible/vm-fc-20260828T154903-e6a9eab041f7.tar.gz` |

## 复现命令

最终配置（破坏性测试，直接接管两块 NVMe）：

```bash
uv run ansible-playbook \
  -i /tmp/opencode/vm-fc.ini \
  test/ansible/vhost-scheduled-pool-fio.yml \
  --limit vm-fc \
  -e @/tmp/opencode/vm-fc-vhost-1m-vars.json
```
