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

基准容器规格：`1c / 1Gi`（v1 曾使用 0.5c/512Mi，后升级以避免 CPU 在所有场景成为瓶颈）

| 场景 | Deployment YAML | JVM 参数 | 资源限制 | 副本数 | 验证目标 |
|------|-----------------|----------|----------|--------|----------|
| `01-default` | `scenarios/01-default.yaml` | 无 | 1c / 1Gi | 1 | 堆上限仅 ~248MB（25%），GC 为 JVM 自动选择 |
| `02-heap-fixed` | `scenarios/02-heap-fixed.yaml` | `-XX:MaxRAMPercentage=75` | 1c / 1Gi | 1 | 堆上限提升至 ~742MB（75%） |
| `03-serial-gc` | `scenarios/03-serial-gc.yaml` | `-XX:+UseSerialGC -XX:MaxRAMPercentage=75` | 1c / 1Gi | 1 | 与 04-g1gc 对比 SerialGC 停顿劣势 |
| `04-g1gc` | `scenarios/04-g1gc.yaml` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 1c / 1Gi | 1 | G1GC 基线（GC max 9ms，总停顿 1,509ms） |
| `05-cpu-throttle` | `scenarios/05-cpu-throttle.yaml` | `-XX:MaxRAMPercentage=75` | 0.25c / 1Gi | 1 | CPU 节流导致 GC 停顿 318ms，业务请求 100% EOF |
| `06-pod-sizing` | `scenarios/06-pod-sizing-small.yaml` / `06-pod-sizing-large.yaml` | `-XX:MaxRAMPercentage=75` | 0.5c × 3 vs 1.5c × 1 | 3 vs 1 | 相同总 CPU（1.5c）下，大副本 GC 停顿 -70%，p95 -37% |
| `07-zgc` | `scenarios/07-zgc.yaml` | `-XX:+UseZGC -XX:MaxRAMPercentage=75` | 1c / 1Gi | 1 | ZGC GC 停顿 1ms（-89% vs G1），但响应时间 +22% |
| `08-g1gc-2c2g` | `scenarios/08-g1gc-2c2g.yaml` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 2c / 2Gi | 1 | 双倍资源下 G1GC 表现 |
| `09-zgc-2c2g` | `scenarios/09-zgc-2c2g.yaml` | `-XX:+UseZGC -XX:MaxRAMPercentage=75` | 2c / 2Gi | 1 | 双倍资源下 ZGC vs G1GC（资源充裕时 ZGC 代价更小） |
| `10-g1gc-4c4g` | `scenarios/10-g1gc-4c4g.yaml` | `-XX:+UseG1GC -XX:MaxRAMPercentage=75` | 4c / 4Gi | 1 | 高配下 G1GC 基线 |
| `11-zgc-4c4g` | `scenarios/11-zgc-4c4g.yaml` | `-XX:+UseZGC -XX:MaxRAMPercentage=75` | 4c / 4Gi | 1 | 高配下 ZGC（预期代价趋近于零） |

---

## 对比关系

```
场景01 vs 场景02  →  默认堆(25%) vs 修复堆(75%)
场景03 vs 场景04  →  SerialGC vs G1GC（相同堆配置下 GC 行为差异）
场景04 vs 场景05  →  充足 CPU vs CPU 节流（250m 下服务完全不可用）
场景06-small vs 场景06-large  →  3×0.5c vs 1×1.5c（总 CPU 相同，大副本 GC 更优）
场景04 vs 场景07  →  G1GC vs ZGC（1c 下 ZGC 停顿更低但吞吐略低）
场景08 vs 场景09  →  2c/2Gi 下 G1GC vs ZGC
场景10 vs 场景11  →  4c/4Gi 下 G1GC vs ZGC（验证资源充裕时 ZGC 优势显现）
```

---

## 数据采集

每个场景的指标通过以下方式采集：

**k6 输出（吞吐 & 延迟）：**
- `http_reqs`：总请求数 / RPS
- `http_req_duration` p95/p99：响应时间
- `http_req_failed`：错误率

**Actuator 端点（JVM 指标）：**
- `jvm.memory.max`：堆上限（验证 ~248MB vs ~742MB）
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
│       ├── 06-pod-sizing-large.yaml
│       ├── 07-zgc.yaml
│       ├── 08-g1gc-2c2g.yaml
│       ├── 09-zgc-2c2g.yaml
│       ├── 10-g1gc-4c4g.yaml
│       └── 11-zgc-4c4g.yaml
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
| 默认堆 vs 修复堆 | 堆上限 248MB → 742MB（实测），内存利用率 25% → 75% |
| SerialGC vs G1GC | GC pause max 从数百ms 降至个位数 ms（待补测 03-serial-gc） |
| 充足CPU vs 节流 | 250m CPU 下 GC 停顿 318ms，业务请求 100% EOF（已实测） |
| 小副本×3 vs 大副本×1 | 大副本 p95 -37%，GC max -70%（已实测） |
| G1GC vs ZGC（1c） | ZGC GC 停顿 -89%，但响应时间 +22%（已实测） |
| G1GC vs ZGC（2c/4c） | 资源充裕时 ZGC 吞吐损耗趋近于零（场景 08-11，待实测） |

---

## 实验时间估算

每场景约 2-3 分钟（含 Pod 启动 + k6 压测 60s + 指标采集），总计约 **20 分钟**。
