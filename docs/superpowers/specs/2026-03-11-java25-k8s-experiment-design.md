# Java 25 on Kubernetes: Default Configuration Experiment Design

**Date:** 2026-03-11
**Reference:** [The State of Java on Kubernetes 2026 – Why Defaults Are Killing Your Performance](https://akamas.io/resources/the-state-of-java-on-kubernetes-2026-why-defaults-are-killing-your-performance/)
**Goal:** 教学演示——用可量化的原始数据验证默认 JVM 配置在 Kubernetes 中导致的三类性能问题。

---

## 问题背景

文章指出三个核心问题：

1. **堆内存浪费**：未设置 `-XX:MaxRAMPercentage` 时，JVM 默认只使用容器内存的 25%（1c2g 容器只获得 ~500MB 堆）
2. **GC 选择不当**：未指定 GC 时，受限容器可能回退到 SerialGC，导致 Stop-the-World 停顿
3. **CPU 节流与 Pod 规格**：CPU Limit < 1 导致严重节流；相同总 CPU 下，大副本优于多个小副本

---

## 技术栈

- Java 25 + Spring Boot 3.5.1 + Spring Actuator
- kind（本地 Kubernetes 集群）
- k6（HTTP 负载测试）
- kubectl（指标采集）

---

## 应用设计

单一 Spring Boot 应用，暴露以下端点：

| 端点 | 用途 |
|------|------|
| `GET /stress/memory?mb=N` | 分配并保留 N MB 对象，触发 GC |
| `GET /stress/cpu?seconds=N` | 纯计算负载（质数筛），压 CPU |
| `GET /actuator/metrics/jvm.gc.pause` | 观察 GC 停顿时间 |
| `GET /actuator/metrics/jvm.memory.used` | 观察堆内存使用量 |
| `GET /actuator/metrics/jvm.memory.max` | 观察堆内存上限（验证是否为 128MB vs 384MB） |
| `GET /health` | 基准延迟测量 |

---

## 实验场景

基准容器规格：`0.5c / 512Mi`

| 场景 | Deployment YAML | JVM 参数 | 资源限制 | 副本数 | 验证目标 |
|------|-----------------|----------|----------|--------|----------|
| `01-default` | `scenarios/01-default.yaml` | 无 | 0.5c / 512Mi | 1 | 堆上限仅 ~128MB（25%），GC 为默认选择 |
| `02-heap-fixed` | `scenarios/02-heap-fixed.yaml` | `-XX:MaxRAMPercentage=75` | 0.5c / 512Mi | 1 | 堆上限提升至 ~384MB（75%） |
| `03-serial-gc` | `scenarios/03-serial-gc.yaml` | `-XX:+UseSerialGC -XX:MaxRAMPercentage=75` | 0.5c / 512Mi | 1 | GC pause 高，吞吐低 |
| `04-g1gc` | `scenarios/04-g1gc.yaml` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 0.5c / 512Mi | 1 | GC pause 低，吞吐高 |
| `05-cpu-throttle` | `scenarios/05-cpu-throttle.yaml` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 0.1c / 512Mi | 1 | CPU 节流，响应时间骤升，吞吐骤降 |
| `06-pod-sizing` | `scenarios/06-pod-sizing-small.yaml` / `06-pod-sizing-large.yaml` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 0.25c × 3 vs 0.75c × 1 | 3 vs 1 | 相同总 CPU 下，大副本吞吐更高 |

---

## 对比关系

```
场景01 vs 场景02  →  默认堆(25%) vs 修复堆(75%)
场景03 vs 场景04  →  SerialGC vs G1GC（相同堆配置下 GC 行为差异）
场景04 vs 场景05  →  充足 CPU vs CPU 节流
场景06-small vs 场景06-large  →  3×0.25c vs 1×0.75c（总 CPU 相同）
```

---

## 数据采集

每个场景的指标通过以下方式采集：

**k6 输出（吞吐 & 延迟）：**
- `http_reqs`：总请求数 / RPS
- `http_req_duration` p95/p99：响应时间
- `http_req_failed`：错误率

**Actuator 端点（JVM 指标）：**
- `jvm.memory.max`：堆上限（验证 128MB vs 384MB）
- `jvm.memory.used`：实际堆使用量
- `jvm.gc.pause`：GC 停顿时间（count + max + sum）

**kubectl 命令：**
- `kubectl top pods`：实时 CPU/内存使用
- `kubectl describe pod`：查看 CPU throttling 事件

---

## 项目结构

```
java25-config-in-k8s/
├── app/                          # Spring Boot 应用
│   ├── src/
│   └── Dockerfile
├── k8s/
│   ├── kind-config.yaml          # kind 集群配置（1 control-plane + 2 workers）
│   └── scenarios/
│       ├── 01-default.yaml
│       ├── 02-heap-fixed.yaml
│       ├── 03-serial-gc.yaml
│       ├── 04-g1gc.yaml
│       ├── 05-cpu-throttle.yaml
│       ├── 06-pod-sizing-small.yaml
│       └── 06-pod-sizing-large.yaml
├── k6/
│   └── load-test.js              # 统一负载脚本
└── scripts/
    ├── setup-cluster.sh          # 创建 kind 集群 + 加载镜像
    ├── run-scenario.sh           # 切换场景 → 等待就绪 → 运行 k6 → 采集 Actuator 指标
    └── collect-metrics.sh        # 从 Actuator 拉取并格式化 JVM 指标
```

---

## 预期结果摘要

| 对比 | 预期差异 |
|------|----------|
| 默认堆 vs 修复堆 | 堆上限 128MB → 384MB，内存利用率 25% → 75% |
| SerialGC vs G1GC | GC pause max 从数百ms 降至数十ms |
| 充足CPU vs 节流 | p95 响应时间 5-10x 差异，RPS 大幅下降 |
| 小副本×3 vs 大副本×1 | 大副本 RPS 明显高于小副本总和 |

---

## 实验时间估算

每场景约 2-3 分钟（含 Pod 启动 + k6 压测 60s + 指标采集），总计约 **20 分钟**。
