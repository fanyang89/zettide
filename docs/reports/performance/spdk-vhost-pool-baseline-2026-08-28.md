# SPDK、raw vhost 与 scheduled Pool 性能基线报告

状态：历史性能报告；只适用于下述 revision、硬件和工作负载，不定义当前产品能力。

日期：2026-08-28

## 摘要

本报告比较同一代码版本、同一组双 NVMe 设备和相同总队列深度下的三条 4 KiB 随机读路径：

- native SPDK NVMe perf；
- raw SPDK NVMe vhost-user-blk；
- Zettide scheduled Pool vhost-user-blk。

每条路径执行两轮 20 秒测量。native SPDK 平均达到 1,174,627 IOPS；raw vhost 平均达到 398,458 IOPS，保留 native 吞吐的 33.92%；scheduled Pool 平均达到 779,885 IOPS，保留 native 吞吐的 66.39%，并达到 raw vhost 的 1.96 倍。

诊断结果表明，raw vhost 的主要额外成本与 virtio 完成通知和 VM 调度路径一致。scheduled Pool 通过批处理和调度将 guest virtio IRQ/IO 降低 76.0%，将 host reschedule IPI/IO 降低 78.8%。它同时引入更多 backend worker CPU、function-call IPI 和上下文切换，但总 CPU/IO 仍比 raw vhost 低 34.6%。

## 测试范围

### 软件版本

| 项目 | 值 |
|---|---|
| Zettide revision | `2e6f67f2fd6b8d4698e6ca942df606af51efb52a` |
| SPDK revision | `c66b97b5275ec6189db11ab2264499133e43d4d4` |
| 构建模式 | `ReleaseSafe` |
| Zig | `0.16.0` |
| fio | `fio-3.40` |
| 远端系统 | Fedora 44，kernel `7.1.9-200.fc44.x86_64` |
| 远端主机 | `vm-fc` |

所有有效归档都记录了相同的 source archive SHA-256 和空的 `source_status`，因此六个样本来自同一份干净源码。

### 硬件与拓扑

使用以下两块 NVMe：

| 设备 | 序列号 | PCIe namespace |
|---|---|---|
| `/dev/nvme1n1` | `PHMB747600DE280CGN` | `0000:04:00.0/1` |
| `/dev/nvme0n1` | `PHMB746600SS280CGN` | `0000:03:00.0/1` |

其他拓扑条件：

- `epy` 为 AMD EPYC 7K62，48 核、96 线程；
- `vm-fc` 提供 24 个 vCPU；
- outer QEMU 线程共享物理 CPU `8-35`，未逐线程固定；
- inner fio guest 使用 8 个 vCPU，映射到 `vm-fc` CPU `16-23`；
- 两个 SPDK reactor 使用 `vm-fc` CPU `0-1`；
- scheduled Pool worker 和非 vCPU QEMU 线程未显式绑定；
- `epy` 和 `vm-fc` 均启用 `irqbalance`；
- 未设置 `mitigations=off`。

本轮测试没有修改 affinity、IRQ、mitigations，也没有重启 `vm-fc` 或 `epy`。

### 工作负载

| 参数 | 值 |
|---|---:|
| IO 模式 | 4 KiB 随机读 |
| 测量时间 | 20 秒 |
| ramp/warmup | 5 秒 |
| vhost fio jobs | 16 |
| 每个 fio job 队列深度 | 32 |
| vhost 总 outstanding IO | 512 |
| native worker 数 | 2 |
| native 每 worker 队列深度 | 256 |
| native 总 outstanding IO | 512 |
| vhost controllers | 2 |
| vhost queues | 8 |
| reactors | 2 |
| Pool workers | 2 |
| concurrent groups | 8 |
| threaded concurrency | 16 |
| inline batches | 0 |
| coalescing delay base | 4 us |
| coalescing IOPS threshold | 10,000 |
| native core mask | `0x3` |

通过让三条路径都保持 512 个 outstanding IO，尽量避免由总队列深度差异造成的吞吐偏差。

## 吞吐与延迟

### 两轮原始结果

| 路径 | 轮次 | IOPS | 带宽 | 平均延迟 | p99 |
|---|---:|---:|---:|---:|---:|
| native SPDK | 1 | 1,174,850.90 | 4,589.26 MiB/s | 435.79 us | 473.508 us/namespace |
| native SPDK | 2 | 1,174,402.25 | 4,587.51 MiB/s | 435.96 us | 473.508 us/namespace |
| raw vhost | 1 | 394,256.26 | 1.504 GiB/s | 1.262 ms | 4.948 ms |
| raw vhost | 2 | 402,659.22 | 1.536 GiB/s | 1.236 ms | 4.948 ms |
| scheduled Pool | 1 | 803,052.69 | 3.063 GiB/s | 626.41 us | 2.605 ms |
| scheduled Pool | 2 | 756,716.39 | 2.887 GiB/s | 664.03 us | 3.719 ms |

native 的 p99 来自每个 namespace 的独立 latency histogram；fio 的 p99 是 vhost 工作负载的聚合结果。两者的统计口径不同，不应将细小差异视为严格的一一对应比较。

### 双轮汇总

| 路径 | 平均 IOPS | 平均带宽 | 平均延迟 | 双轮离散幅度 |
|---|---:|---:|---:|---:|
| native SPDK | **1,174,627** | 4.481 GiB/s | 435.88 us | 0.038% |
| raw vhost | **398,458** | 1.520 GiB/s | 1.249 ms | 2.11% |
| scheduled Pool | **779,885** | 2.975 GiB/s | 645.22 us | 5.94% |

离散幅度按两轮最大值与最小值之差除以均值计算。

### 相对结果

| 比较项 | 结果 |
|---|---:|
| raw vhost 相对 native 的吞吐损失 | 66.08% |
| scheduled Pool 相对 native 的吞吐损失 | 33.61% |
| scheduled Pool 相对 raw vhost 的吞吐倍数 | 1.96 倍 |
| raw vhost 平均延迟相对 native | 2.87 倍 |
| scheduled Pool 平均延迟相对 native | 1.48 倍 |
| scheduled Pool 平均延迟相对 raw vhost 的降幅 | 48.3% |

native 两轮仅相差约 0.04%，说明介质和 direct SPDK 基线非常稳定。raw vhost 的 2.11% 离散幅度也较小。scheduled Pool 的离散幅度达到 5.94%，其中第二轮相对第一轮下降 5.77%，因此当前样本足以支持数量级较大的差异，但不足以可靠判断低于约 5% 的微小优化。

## CPU 效率

vhost 路径的 CPU 来自 measured window 内 `pidstat` 的 target 和 QEMU 进程平均 CPU。100% CPU 计为一个持续占用的逻辑核。归一化指标的计算方式为：

```text
core-s/百万 IO = 平均占用核数 / (IOPS / 1,000,000)
```

native 使用 `0x3` core mask，按两个持续 polling 的 SPDK worker 核估算。该值不包含未被单独采样的低占用辅助线程，因此应视为近似值。

| 路径 | 平均 target/native 核数 | 平均 QEMU/guest 核数 | target/native core-s/百万 IO | QEMU/guest core-s/百万 IO | 合计 core-s/百万 IO |
|---|---:|---:|---:|---:|---:|
| native SPDK | 2.000 | - | 1.70 | - | **1.70** |
| raw vhost | 1.994 | 7.900 | 5.00 | 19.83 | **24.83** |
| scheduled Pool | 4.777 | 7.888 | 6.12 | 10.11 | **16.24** |

raw vhost 和 scheduled Pool 都让约八个 guest vCPU 接近满载。scheduled Pool 使用更多 backend CPU，但相同 guest CPU 承载了约 1.96 倍 IOPS，因此其 QEMU/guest CPU/IO 几乎减半，总 CPU/IO 比 raw vhost 低 34.6%。

## 中断与调度

下表将两轮 counter delta 合并后按完成 IO 数归一化：

| 指标 | native SPDK | raw vhost | scheduled Pool |
|---|---:|---:|---:|
| guest virtio IRQ/IO | - | 0.593 | 0.142 |
| host reschedule IPI/IO | 0.000014 | 0.680 | 0.144 |
| host function-call IPI/IO | 0.000321 | 0.000812 | 0.378 |
| host softirq/百万 IO | 697 | 3,558 | 5,317 |
| guest softirq/百万 IO | - | 6,621 | 3,339 |
| target voluntary context switch/IO | - | 0.000002 | 0.265 |

线程迁移观测：

- raw vhost target 两轮均未迁移；QEMU 线程共迁移 4 次；
- scheduled Pool target 两轮共迁移 22 次；QEMU 线程共迁移 12 次；
- scheduled Pool 的迁移主要来自未绑定的 worker，而两个 reactor 没有迁移。

与 raw vhost 相比，scheduled Pool 的 guest virtio IRQ/IO 下降 76.0%，host reschedule IPI/IO 下降 78.8%。这与 scheduled Pool 使用批处理和调度合并完成通知的设计一致，也解释了为什么相同的 guest CPU 能处理接近两倍的 IO。

scheduled Pool 同时产生大量 function-call IPI 和 target voluntary context switch。这些计数反映 backend dispatch 和 worker 协作成本，是 Pool 仍低于 native SPDK 的一部分原因。由于本轮没有实施 CPU 隔离或 affinity 对照实验，这些数据说明的是强相关关系，而不是单独变量控制后的因果证明。

native SPDK measured window 内没有可见的 NVMe 完成 MSI-X 增量；IO 完成依靠 polling。两轮合计每百万 IO 仅约 14.3 次 reschedule IPI，显著低于两条虚拟化路径。

## 结论

1. 两块 NVMe 的 native SPDK 上限约为 1.175 M IOPS，且双轮结果高度稳定。
2. raw vhost 只能达到约 0.398 M IOPS。两个 reactor 和八个 guest vCPU 已接近满载，guest virtio IRQ 和 host reschedule IPI 密度都很高，完成通知路径是首要优化对象。
3. scheduled Pool 达到约 0.780 M IOPS。它不是零成本抽象，但通过减少完成通知和 guest 调度开销，使吞吐达到 raw vhost 的 1.96 倍，并将总 CPU/IO 降低 34.6%。
4. scheduled Pool 距 native 仍有 33.6% 吞吐差距。后续优化应优先关注 Pool worker dispatch、function-call IPI、voluntary context switch，以及未绑定 worker 的运行位置。
5. scheduled Pool 当前双轮波动约为 6%。在判断小于 5% 的改动前，应增加到至少五轮，并报告中位数和离散区间。

## 有效性与限制

- 六轮 lifecycle 均记录 `test_succeeded=true`、`command_rc=0`、`cleanup_rc=0`；
- 每轮结束后，两块设备均恢复到 Linux `nvme` 驱动；
- fio JSON 在解析前经过前导文本归一化，最终仍由 `jq` 验证完整性；
- outer QEMU 线程共享物理 CPU，且 `irqbalance` 开启，因此 host 调度噪声没有被完全隔离；
- 本轮没有关闭 CPU 安全缓解措施，也没有修改 IRQ affinity；
- 只有两个样本，尤其是 scheduled Pool 的细粒度稳定性仍需更多轮次验证；
- native lifecycle 的通用字段错误地记录了 `benchmark_mode=pool`。manifest 正确记录 `profile=spdk-nvme-perf` 和 `pool_fio_source_profile=native`，实际日志也确认运行的是直接 SPDK NVMe perf。该问题仅影响 lifecycle 元数据，不影响本次执行路径和测量结果。

## 归档索引

### 第一轮

| 路径 | 归档 |
|---|---|
| raw vhost | `test-results/ansible/vm-fc-20260828T131007-2e6f67f2fd6b.tar.gz` |
| scheduled Pool | `test-results/ansible/vm-fc-20260828T131452-2e6f67f2fd6b.tar.gz` |
| native SPDK | `test-results/ansible/vm-fc-20260828T131947-2e6f67f2fd6b.tar.gz` |

### 第二轮

| 路径 | 归档 |
|---|---|
| scheduled Pool | `test-results/ansible/vm-fc-20260828T132402-2e6f67f2fd6b.tar.gz` |
| raw vhost | `test-results/ansible/vm-fc-20260828T132836-2e6f67f2fd6b.tar.gz` |
| native SPDK | `test-results/ansible/vm-fc-20260828T133321-2e6f67f2fd6b.tar.gz` |

## 复现命令

原始运行的公共参数保存在执行主机的 `/tmp/opencode/vm-fc-vhost-baseline-vars.json`，inventory 保存在 `/tmp/opencode/vm-fc.ini`；这些临时文件不由仓库保存，因此以下命令是历史命令模板，不是独立可复现入口。测试会直接操作并临时接管两块 NVMe，属于破坏性测试。

scheduled Pool：

```bash
ANSIBLE_CONFIG=tests/automation/ansible.cfg uv run --project tests/automation ansible-playbook \
  -i /tmp/opencode/vm-fc.ini \
  tests/automation/vhost-scheduled-pool-fio.yml \
  --limit vm-fc \
  -e @/tmp/opencode/vm-fc-vhost-baseline-vars.json
```

raw vhost：

```bash
ANSIBLE_CONFIG=tests/automation/ansible.cfg uv run --project tests/automation ansible-playbook \
  -i /tmp/opencode/vm-fc.ini \
  tests/automation/vhost-spdk-nvme-fio.yml \
  --limit vm-fc \
  -e @/tmp/opencode/vm-fc-vhost-baseline-vars.json
```

native SPDK：

```bash
ANSIBLE_CONFIG=tests/automation/ansible.cfg uv run --project tests/automation ansible-playbook \
  -i /tmp/opencode/vm-fc.ini \
  tests/automation/spdk-nvme-perf.yml \
  --limit vm-fc \
  -e @/tmp/opencode/vm-fc-vhost-baseline-vars.json
```
