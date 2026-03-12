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
| **GC 累计停顿** | 1,574 ms | **5 ms** | **ZGC 降低 99.7%** |
| **GC 最大停顿** | 9 ms | **1 ms** | **ZGC 降低 89%** |
| **平均响应时间 (avg)** ① | **8.14 ms** | 10.46 ms | G1GC 在 1c 环境下略优（待重测） |
| **P95 响应时间** ① | **17.76 ms** | 22.92 ms | G1GC 在 1c 环境下略优（待重测） |
| **吞吐量 (RPS)** ① | ~92.6 req/s | ~90.9 req/s | 基本持平（待重测） |

> ① k6 中 40% CPU 压力请求因 `int seconds` 参数无法解析 `seconds=0.3` 而全部返回 400，已修复为 `double seconds`。延迟数据取 `expected_response:true` 过滤后的成功请求均值，但整体负载与设计不符，代码修复后需重新实验。

### 核心观察
1. **极致低停顿**：ZGC 展示了压倒性的停顿优势，将累计停顿时间从 1.5 秒级别直接拉低到个位数毫秒级。
2. **资源权衡**：在单核（1.0c）受限环境下，ZGC 的并发回收会与业务线程轻微争抢 CPU，导致平均延迟略高于 G1GC（约 29%）。
3. **尾延迟注意**：ZGC 的 GC 最大停顿保持在 0–1 ms，但在本实验（纯内存分配）负载下，ZGC 的 p99 为 243 ms，在增加 CPU 规格后也未见改善（4c 时仍为 242 ms）。ZGC 的核心价值是 **GC 停顿上限可控**，而非整体尾延迟更低。

详细报告请参考：`results/gc-comparison-report.md`

## 全场景测试结果汇总

以下是在相同资源（除非场景另有说明，均为 1c/1Gi）和压力环境下的对比：

| 场景 | 核心配置 | RPS ① | Avg Latency ① | P95 Latency ① | 核心观察 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **01 Default** | 默认 (25% Heap) | ~92.1 | 待重测 | 待重测 | 堆上限仅 247.5 MB（25%），GC 累计 5,740 ms |
| **02 Heap Fixed** | 75% Heap | ~92.3 | 待重测 | 待重测 | 堆上限 742 MB；同负载下 GC 次数与 01 相近 |
| **03 SerialGC** | SerialGC | 2.11 | 4.43 s ① | 7.95 s ① | 单核 STW 影响极大；实际 STW 延迟比均值更高 |
| **04 G1GC** | G1GC (Baseline) | ~92.6 | **8.14 ms** | **17.76 ms** | GC 停顿最优的通用基线 |
| **05 Throttled** | 250m CPU | — | — | — | 服务存活，业务请求 100% EOF；GC 最大停顿 318 ms |
| **06-Small** | 1 × 0.5c Pod ② | 待重测 | 待重测 | 待重测 | 单 Pod 性能；0.5c 下预热需≥40s，历史数据存疑 |
| **06-Large** | 1 × 1.5c Pod ② | 待重测 | 待重测 | 待重测 | 单 Pod 性能；与 Small 做 CPU 规格对比 |
| **07 ZGC** | ZGC | ~90.9 | 10.46 ms | 22.92 ms | GC 停顿降低 99.7%；CPU 成本约 +2 ms |

> ① **所有延迟/RPS 数据需重测**：k6 中 40% 的 CPU 压力请求（`/stress/cpu?seconds=0.3`）因 `int` 参数类型不匹配全部返回 400，已修复为 `double seconds`。表中数值为修复前成功请求（`expected_response:true`）均值，整体负载与设计不符。
> ② 场景 06 通过 `kubectl port-forward` 路由，只能连接到 3 个 Pod 中的 1 个，实际对比的是 0.5c 单 Pod vs 1.5c 单 Pod，而非集群总吞吐对比。

## 场景 05 分析：为什么 250m CPU 会导致 EOF

### 故障现象

k6 日志中出现两类错误，按时间顺序先后出现：

```
EOF             # 连接建立成功，但服务端未发送任何 HTTP 数据就关闭
connection refused  # 之后所有请求，连 TCP 握手都无法完成
```

这是两个独立机制的级联失败，不是同一个问题。

### 阶段一：EOF —— CFS 节流使 Tomcat 无法写响应

Linux CFS（完全公平调度器）对 CPU limit 的实现是**时间配额**，而非速率限制：

```
250m = 每 100ms 周期内，容器最多使用 25ms CPU
       用完 25ms 后，进程被强制挂起，等待下一个周期
```

TCP 握手由内核完成，不消耗容器的 CPU 配额，所以连接可以建立。但 Tomcat worker 线程读取 socket、解析 HTTP、执行业务逻辑、写响应，这些都需要进程 CPU 时间。在 25ms/100ms 的配额下，Tomcat 线程极大概率在处理请求途中被挂起，内核检测到 socket 长时间无进展后发送 RST/FIN，客户端收到 EOF。

```
k6 发送 GET /stress/memory
    ↓
kernel 完成 TCP 三次握手（不耗 app CPU）
    ↓
Tomcat worker 开始读 socket → CFS 配额耗尽，进程睡眠 75ms
    ↓
kernel 超时，关闭半开连接
    ↓
k6 收到 EOF（无任何 HTTP 响应头）
```

GC 同样受影响：正常 30ms 的 GC 停顿因 GC 线程被反复打断，实测拉长到 318ms（11 倍）。

### 阶段二：connection refused —— port-forward 隧道崩溃

`kubectl port-forward` 通过 HTTP/2 长连接维持本地端口到 Pod 的隧道。大量并发 EOF 冲击隧道后，port-forward 进程本身崩溃，本地端口消失，此后所有请求直接 connection refused。

这意味着实验日志中的错误混合了**两个独立问题**：Pod 侧无法响应（EOF）和观测通道本身断掉（connection refused），使故障看起来比实际更严重。

### 500m 能解决 EOF 吗

场景 06-pod-small（`cpu: 500m`）已经给出了答案：

| CPU limit | EOF | RPS | avg 延迟 |
|-----------|-----|-----|---------|
| 250m（场景 05）| 100% | — | — |
| **500m（场景 06-small）** | **0%** | **3.66** | **2.54 s** |
| 1000m（场景 04）| 0% | ~92 | ~8 ms |

500m（50ms/100ms）使 Tomcat worker 在单个时间窗口内有机会跑完一次请求，消除了 EOF，但延迟比 1c 慢约 300 倍，RPS 降低 96%。服务在 Kubernetes 健康检查视角下是健康的，但对业务几乎不可用。

### 根本原因与建议

**Spring Boot 应用的 CPU 下限约为 500m**（不 EOF 的最低门槛），但生产可用的下限建议是 **1000m**。低于 500m 时，CFS 节流会使 JVM 的 GC 线程、JIT 编译线程、Tomcat acceptor 互相争抢极少的时间配额，导致结构性不可用。

```yaml
# 最低：避免 EOF
resources:
  limits:
    cpu: "500m"

# 推荐：正常服务
resources:
  limits:
    cpu: "1000m"
```

同时建议显式告知 JVM 实际可用核数，防止其按宿主机核数初始化过多线程加剧争抢：

```
-XX:ActiveProcessorCount=1
```

## 资源进阶对比：2c2g 环境下的 G1GC vs ZGC

当资源提升至 2.0c CPU / 2.0Gi Memory 时，两者的表现：

| 指标 | G1GC (Scenario 08) | ZGC (Scenario 09) | 结论 |
| :--- | :--- | :--- | :--- |
| **GC 累计停顿** | 1,097 ms | **< 1 ms** | ZGC 优势依然巨大 |
| **平均响应时间 (avg)** ① | **8.65 ms** | 10.5 ms | 差距未随 CPU 增加缩小（待重测） |
| **P95 响应时间** ① | **18.45 ms** | 21.85 ms | 表现相当（待重测） |
| **吞吐量 (RPS)** ① | ~92.2 | ~90.9 | 基本持平（待重测） |

### 结论：
- **GC 停顿不随资源扩展**：ZGC 的 GC 停顿时间不随堆大小和 CPU 增加而增加，保持在亚毫秒级。
- **平均延迟代价固定**：2c 下 ZGC 平均延迟仍比 G1GC 高约 1.8 ms，该差距在增加资源后并未缩小（见 4c 对比数据）。

## 资源进阶对比：4c4g 环境下的 G1GC vs ZGC

当资源提升至 4.0c CPU / 4.0Gi Memory 时，两者的表现：

| 指标 | G1GC (Scenario 10) | ZGC (Scenario 11) | 结论 |
| :--- | :--- | :--- | :--- |
| **GC 累计停顿** | 668 ms | **1 ms** | ZGC 停顿优势持续 |
| **平均响应时间 (avg)** ① | **8.19 ms** | 11.52 ms | ZGC 代价在 4c 下未收窄（待重测） |
| **P95 响应时间** ① | **18.6 ms** | 20.92 ms | 差距缩小但仍存在（待重测） |
| **吞吐量 (RPS)** ① | ~92.5 | ~90.2 | 基本持平（待重测） |

### 总结与最终建议：
- **可预测 GC 上限**：ZGC 的 GC 最大停顿在所有资源规格下均保持在 0–1 ms，是 G1GC 无法达到的停顿上限保证。
- **平均延迟代价固定，不随 CPU 改善**：在本实验负载下，ZGC 平均延迟比 G1GC 高约 2–3 ms，且从 1c 扩容至 4c 过程中差距未收窄。
- **p99 尾延迟**：G1GC 的 p99 随 CPU 增加从 121 ms 降至 87 ms（趋势稳定）；ZGC 的 p99 在 4c 时为 242 ms（高于 2c 的 128 ms），对短生命周期对象负载的尾延迟控制弱于 G1GC。
- **选型建议**：当业务对 GC 停顿上限有硬性要求（如 SLA ≤ 5 ms 停顿）时，ZGC 是明确选择；追求平均延迟或 p99 稳定性时，≤4c 环境中 G1GC 表现更优。
