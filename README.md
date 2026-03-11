# Java 25 Config in Kubernetes

一个用 `Spring Boot + kind + k6` 复现实验的教学仓库，用来验证 Java 25 应用在 Kubernetes 中的几类常见配置问题：默认堆过小、GC 选择、CPU 节流，以及 Pod 规格差异。

当前仓库已经补齐 `G1GC` 与 `ZGC` 的一对一对比场景，便于在相同资源和相同负载下继续做低停顿 GC 基准。

## 项目结构

```text
.
├── app/        # Spring Boot 3.5.1 + Actuator 压测应用
├── docs/       # 实验设计文档
├── k6/         # k6 负载脚本
├── k8s/        # kind 配置与实验场景 YAML
├── results/    # 已生成的原始结果与实验报告
└── scripts/    # 集群初始化、单场景执行、批量执行、指标采集脚本
```

## 依赖

- Java 25
- Maven 3.9+
- Docker
- kind
- kubectl
- k6

## 本地运行

先启动应用测试，确认代码可构建：

```bash
cd app
mvn test
```

准备 kind 集群并加载镜像：

```bash
bash scripts/setup-cluster.sh
```

运行单个场景：

```bash
bash scripts/run-scenario.sh 01-default
bash scripts/run-scenario.sh 04-g1gc
bash scripts/run-scenario.sh 07-zgc
```

批量运行全部场景：

```bash
bash scripts/run-all-scenarios.sh
```

## 场景说明

| 场景 | JVM 参数 | 资源 | 用途 |
|------|----------|------|------|
| `01-default` | 无 | 1c / 1Gi | 观察 JVM 默认只取约 25% 容器内存 |
| `02-heap-fixed` | `-XX:MaxRAMPercentage=75` | 1c / 1Gi | 验证显式放大堆后的变化 |
| `03-serial-gc` | `-XX:+UseSerialGC -XX:MaxRAMPercentage=75` | 1c / 1Gi | 作为显式 SerialGC 对照组 |
| `04-g1gc` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 1c / 1Gi | 作为显式 G1GC 基线 |
| `05-cpu-throttle` | `-XX:MaxRAMPercentage=75` | 250m / 1Gi | 观察 CPU 节流下的退化 |
| `06-pod-sizing-small` | `-XX:MaxRAMPercentage=75` | 0.5c / 1Gi × 3 | 小 Pod 规格对照 |
| `06-pod-sizing-large` | `-XX:MaxRAMPercentage=75` | 1.5c / 1Gi × 1 | 大 Pod 规格对照 |
| `07-zgc` | `-XX:+UseZGC -XX:MaxRAMPercentage=75` | 1c / 1Gi | 与 `04-g1gc` 做同条件 GC 对比 |

## ZGC vs G1GC 对比方法

新增的 `07-zgc` 复用了现有压测和指标采集流程，推荐这样执行：

```bash
bash scripts/run-scenario.sh 04-g1gc
bash scripts/run-scenario.sh 07-zgc
```

完成后重点查看：

- `results/*-04-g1gc.txt` 与 `results/*-07-zgc.txt`
- `http_req_duration` 的 `p95` / `p99`
- `jvm.gc.pause` 的 `MAX` / `TOTAL_TIME`
- `jvm.memory.used` 与 `jvm.memory.max`

## 结果文件

- 当前实验报告：`results/experiment-report-v2.md`
- 历史实验报告：`results/experiment-report.md`
- 每次场景执行输出：`results/<timestamp>-<scenario>.txt`
- 批量执行生成的 k6 汇总：`results/*-k6.json`

## 说明

仓库中的 `results/experiment-report-v2.md` 已为 `07-zgc` 预留了报告位点，但不会写入虚构数据。运行完场景后，建议把同一轮环境下的 `04-g1gc` 与 `07-zgc` 实测结果回填到报告中，确保对比成立。

## 实验结果展示 (Java 25)

在 1.0c CPU / 1.0Gi Memory 限制下，针对 **G1GC** 与 **ZGC** 的 60 秒压测对比（10 VUs）：

| 指标 | G1GC (Scenario 04) | ZGC (Scenario 07) | 结论 |
| :--- | :--- | :--- | :--- |
| **GC 累计停顿** | 1,509 ms | **4 ms** | **ZGC 降低 99.7%** |
| **GC 最大停顿** | 9 ms | **1 ms** | **ZGC 降低 89.0%** |
| **平均响应时间 (avg)** | **7.37 ms** | 9.01 ms | G1GC 在 1c 环境下略优 |
| **P95 响应时间** | **17.43 ms** | 22.11 ms | G1GC 在 1c 环境下略优 |
| **吞吐量 (RPS)** | 92.76 req/s | 91.35 req/s | 基本持平 |

### 核心观察
1. **极致低停顿**：ZGC 展示了压倒性的停顿优势，将累计停顿时间从 1.5 秒级别直接拉低到个位数毫秒级。
2. **资源权衡**：在单核（1.0c）受限环境下，ZGC 的并发回收会与业务线程轻微争抢 CPU，导致平均延迟略高于 G1GC（约 20%）。
3. **Java 25 稳定性**：在相同负载下，Java 25 的 ZGC 表现出极高的稳定性，适合对 P99/P999 延迟有严苛要求的生产环境。

详细报告请参考：`results/zgc-vs-g1gc-comparison.md`

## 全场景测试结果汇总

以下是在相同资源（除非场景另有说明，均为 1c/1Gi）和压力环境下的对比：

| 场景 | 核心配置 | RPS | Avg Latency | P95 Latency | 核心观察 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **01 Default** | 默认 (25% Heap) | 92.05 | 8.16 ms | 18.60 ms | Java 25 默认配置已较稳健 |
| **02 Heap Fixed** | 75% Heap | 92.29 | 7.90 ms | 18.83 ms | 放大堆容量对该负载无显著收益 |
| **03 SerialGC** | SerialGC | 2.11 | 4.43 s | 7.95 s | 单核限制下 STW 影响极大 |
| **04 G1GC** | G1GC (Baseline) | **92.76** | **7.37 ms** | **17.43 ms** | 平衡性最佳的通用选择 |
| **05 Throttled** | 250m CPU | 98.23 | <1 ms* | <1 ms* | CPU 节流导致大面积处理异常 |
| **06-Small** | 3 x 0.25c Pods | 3.66 | 2.54 s | 4.24 s | 资源过碎导致启动/预热极其缓慢 |
| **06-Large** | 1 x 0.75c Pod | 2.65 | 3.56 s | 6.91 s | 相比碎 Pod，大 Pod 稳定性更好 |
| **07 ZGC** | ZGC | 91.35 | 9.01 ms | 22.11 ms | 停顿降低 99%，但 CPU 成本略高 |

> *注：场景 05 的延迟显示极低是因为 CPU 被极度节流后，Spring Boot 无法正常处理请求，返回的大多是快速失败或超时。*

## 资源进阶对比：2c2g 环境下的 G1GC vs ZGC

当资源提升至 2.0c CPU / 2.0Gi Memory 时，两者的表现：

| 指标 | G1GC (Scenario 08) | ZGC (Scenario 09) | 结论 |
| :--- | :--- | :--- | :--- |
| **GC 累计停顿** | 1,040 ms | **1 ms** | ZGC 优势依然巨大 |
| **平均响应时间 (avg)** | **7.98 ms** | 9.37 ms | 差距进一步缩小 |
| **P95 响应时间** | **18.13 ms** | 21.63 ms | 表现相当 |
| **吞吐量 (RPS)** | 92.19 | 91.04 | 基本持平 |

### 结论：
- **资源不敏感度**：ZGC 的停顿时间几乎不随堆大小和资源增加而增加，表现出极强的线性一致性。
- **多核收益**：在 2c 环境下，ZGC 的并发回收对业务的影响变得更小，适合在更充裕的资源规格下使用以换取极致的低延迟。

## 资源进阶对比：4c4g 环境下的 G1GC vs ZGC

当资源提升至 4.0c CPU / 4.0Gi Memory 时，两者的表现：

| 指标 | G1GC (Scenario 10) | ZGC (Scenario 11) | 结论 |
| :--- | :--- | :--- | :--- |
| **GC 累计停顿** | 653 ms | **1 ms** | ZGC 停顿表现依然完美 |
| **平均响应时间 (avg)** | **7.75 ms** | 8.73 ms | 延迟表现已非常接近 |
| **P95 响应时间** | **17.75 ms** | 19.24 ms | 响应质量基本对等 |
| **吞吐量 (RPS)** | 92.26 | 91.50 | 吞吐量一致 |

### 总结与最终建议：
- **可预测性**：ZGC 提供了极其稳定的**可预测停顿**。无论业务负载如何波动、堆内存如何增长，GC 停顿始终保持在亚毫秒级。
- **资源与延迟的平衡**：
    - 在 **CPU 极度受限 (<=1c)** 的环境下，G1GC 的吞吐量表现略好。
    - 在 **CPU 资源充足 (>=2c)** 的环境下，强烈建议开启 ZGC 以获取极低的 P99 延迟。
- **Java 25 的代际红利**：在 Java 25 中，ZGC 已完全成熟并推荐作为高并发、低延迟应用的默认选择。
