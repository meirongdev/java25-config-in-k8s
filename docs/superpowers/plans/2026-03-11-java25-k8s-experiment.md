# Java 25 on Kubernetes Default Config Experiment — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个可复现的实验套件，通过 Spring Boot 应用 + kind 集群 + k6 压测，量化验证默认 JVM 配置在 Kubernetes 中导致的三类性能问题。

**Architecture:** 单一 Spring Boot 应用镜像，通过 K8s Deployment 的不同 `JAVA_TOOL_OPTIONS` 环境变量和 `resources` 限制切换实验场景。k6 通过 `kubectl port-forward` 打压应用，JVM 指标从 Spring Actuator 采集，CPU 指标从 `kubectl top` 采集。

**Tech Stack:** Java 25, Spring Boot 3.5.1, Spring Actuator, Maven, Docker, kind, kubectl, k6

---

## File Structure

```
java25-config-in-k8s/
├── app/                                          # Spring Boot 应用（Spring Initializr 生成）
│   ├── pom.xml
│   ├── mvnw
│   ├── Dockerfile
│   └── src/
│       ├── main/java/dev/meirong/k8sexperiment/
│       │   ├── K8sExperimentApplication.java     # 主类（Initializr 生成，保持不动）
│       │   ├── StressController.java             # HTTP 端点
│       │   └── StressService.java                # 内存/CPU 压力逻辑
│       ├── main/resources/
│       │   └── application.properties            # Actuator 配置
│       └── test/java/dev/meirong/k8sexperiment/
│           └── StressControllerTest.java         # 集成测试
├── k8s/
│   ├── kind-config.yaml                          # kind 3节点集群配置
│   └── scenarios/
│       ├── 01-default.yaml                       # 无JVM参数，0.5c/512Mi
│       ├── 02-heap-fixed.yaml                    # MaxRAMPercentage=75
│       ├── 03-serial-gc.yaml                     # UseSerialGC + heap fix
│       ├── 04-g1gc.yaml                          # UseG1GC + heap fix
│       ├── 05-cpu-throttle.yaml                  # 0.1c/512Mi
│       ├── 06-pod-sizing-small.yaml              # 3副本 × 0.25c
│       └── 06-pod-sizing-large.yaml              # 1副本 × 0.75c
├── k6/
│   └── load-test.js                              # 统一负载脚本（60s, 10 VUs）
└── scripts/
    ├── setup-cluster.sh                          # 创建集群 + 构建镜像 + 加载到kind
    ├── run-scenario.sh                           # 切换场景 → 等待就绪 → 跑k6 → 采集指标
    └── collect-metrics.sh                        # 从 Actuator 格式化输出JVM指标
```

---

## Chunk 1: Spring Boot Application

### Task 1: Bootstrap Maven project

**Files:**
- Create: `app/` (via Spring Initializr)
- Modify: `app/pom.xml`

- [ ] **Step 1: 用 Spring Initializr 生成基础项目**

```bash
cd /path/to/java25-config-in-k8s
curl https://start.spring.io/starter.tgz \
  -d type=maven-project \
  -d language=java \
  -d bootVersion=3.5.1 \
  -d baseDir=app \
  -d groupId=dev.meirong \
  -d artifactId=k8s-experiment \
  -d name=k8s-experiment \
  -d packageName=dev.meirong.k8sexperiment \
  -d javaVersion=25 \
  -d dependencies=web,actuator \
  | tar -xzvf -
```

预期：生成 `app/` 目录，包含 `pom.xml`、`mvnw`、`.mvn/`、`src/`。

- [ ] **Step 2: 验证 pom.xml 的 Java 版本配置**

打开 `app/pom.xml`，确认以下内容存在：
```xml
<properties>
    <java.version>25</java.version>
</properties>
```

- [ ] **Step 3: 验证项目能编译**

```bash
cd app && ./mvnw compile -q
```

预期：无报错，`BUILD SUCCESS`。

- [ ] **Step 4: Commit**

```bash
git add app/
git commit -m "chore: bootstrap Spring Boot 3.5.1 + Java 25 project"
```

---

### Task 2: Configure Actuator and virtual threads

**Files:**
- Modify: `app/src/main/resources/application.properties`

- [ ] **Step 1: 替换 application.properties**

将 `app/src/main/resources/application.properties` 的内容替换为：

```properties
# Actuator: 暴露所有需要的端点
management.endpoints.web.exposure.include=health,metrics,info
management.endpoint.health.show-details=always

# 开启虚拟线程（Java 25 特性）
spring.threads.virtual.enabled=true

server.port=8080
```

- [ ] **Step 2: 验证应用能启动**

```bash
cd app && ./mvnw spring-boot:run &
sleep 8
curl -s http://localhost:8080/actuator/health | python3 -m json.tool
kill %1
```

预期输出包含 `"status": "UP"`。

- [ ] **Step 3: Commit**

```bash
git add app/src/main/resources/application.properties
git commit -m "chore: configure Actuator endpoints and enable virtual threads"
```

---

### Task 3: Write StressService (TDD)

**Files:**
- Create: `app/src/test/java/dev/meirong/k8sexperiment/StressControllerTest.java`
- Create: `app/src/main/java/dev/meirong/k8sexperiment/StressService.java`

- [ ] **Step 1: 写失败测试**

创建 `app/src/test/java/dev/meirong/k8sexperiment/StressControllerTest.java`：

```java
package dev.meirong.k8sexperiment;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class StressControllerTest {

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void memoryStress_allocatesGarbageAndReturnsStats() {
        var response = restTemplate.getForEntity("/stress/memory?mb=5", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsKey("allocated_mb");
        assertThat(response.getBody()).containsKey("duration_ms");
    }

    @Test
    void cpuStress_runsComputationAndReturnsPrimeCount() {
        // seconds=0 让计算立即结束，避免测试变慢
        var response = restTemplate.getForEntity("/stress/cpu?seconds=0", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsKey("primes_found");
    }

    @Test
    void health_returnsUp() {
        var response = restTemplate.getForEntity("/actuator/health", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
cd app && ./mvnw test -Dtest=StressControllerTest -q 2>&1 | tail -5
```

预期：`BUILD FAILURE`，错误含 `404` 或 `NoSuchBeanDefinitionException`（因为 Controller 还不存在）。

- [ ] **Step 3: 创建 StressService**

创建 `app/src/main/java/dev/meirong/k8sexperiment/StressService.java`：

```java
package dev.meirong.k8sexperiment;

import org.springframework.stereotype.Service;
import java.util.Arrays;

@Service
public class StressService {

    /**
     * 分配 mb 兆字节的短生命周期对象，主动触发 GC。
     * 每次 1MB 一个 chunk，填充内容防止 JIT 优化掉分配。
     */
    public long allocateGarbage(int mb) {
        long start = System.currentTimeMillis();
        for (int i = 0; i < mb; i++) {
            byte[] chunk = new byte[1024 * 1024];
            Arrays.fill(chunk, (byte) (i & 0xFF));
            // chunk 在下次循环时成为垃圾，触发 GC
        }
        return System.currentTimeMillis() - start;
    }

    /**
     * 持续计算质数，直到 seconds 秒超时。
     * 用于产生 CPU 压力。
     */
    public long computePrimes(int seconds) {
        long endTime = System.currentTimeMillis() + ((long) seconds * 1000);
        long count = 0;
        long n = 2;
        while (System.currentTimeMillis() < endTime) {
            if (isPrime(n)) count++;
            n++;
        }
        return count;
    }

    private boolean isPrime(long n) {
        if (n < 2) return false;
        for (long i = 2; i * i <= n; i++) {
            if (n % i == 0) return false;
        }
        return true;
    }
}
```

- [ ] **Step 4: 创建 StressController**

创建 `app/src/main/java/dev/meirong/k8sexperiment/StressController.java`：

```java
package dev.meirong.k8sexperiment;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.Map;

@RestController
@RequestMapping("/stress")
public class StressController {

    private final StressService stressService;

    public StressController(StressService stressService) {
        this.stressService = stressService;
    }

    /**
     * 分配短生命周期对象触发 GC。
     * 观察指标：jvm.gc.pause（通过 Actuator）
     */
    @GetMapping("/memory")
    public ResponseEntity<Map<String, Object>> stressMemory(
            @RequestParam(defaultValue = "50") int mb) {
        long durationMs = stressService.allocateGarbage(mb);
        return ResponseEntity.ok(Map.of(
                "allocated_mb", mb,
                "duration_ms", durationMs
        ));
    }

    /**
     * 纯 CPU 计算压力。
     * 观察指标：kubectl top pods（通过外部工具）
     */
    @GetMapping("/cpu")
    public ResponseEntity<Map<String, Object>> stressCpu(
            @RequestParam(defaultValue = "2") int seconds) {
        long primesFound = stressService.computePrimes(seconds);
        return ResponseEntity.ok(Map.of(
                "duration_seconds", seconds,
                "primes_found", primesFound
        ));
    }
}
```

- [ ] **Step 5: 运行测试，确认通过**

```bash
cd app && ./mvnw test -Dtest=StressControllerTest -q
```

预期：`Tests run: 3, Failures: 0, Errors: 0`，`BUILD SUCCESS`。

- [ ] **Step 6: Commit**

```bash
git add app/src/
git commit -m "feat: add StressController and StressService for GC/CPU pressure generation"
```

---

### Task 4: Dockerfile

**Files:**
- Create: `app/Dockerfile`

- [ ] **Step 1: 创建多阶段 Dockerfile**

创建 `app/Dockerfile`：

```dockerfile
# Stage 1: Build
FROM eclipse-temurin:25-jdk AS build
WORKDIR /app
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN ./mvnw dependency:go-offline -q
COPY src ./src
RUN ./mvnw package -DskipTests -q

# Stage 2: Runtime（Java 25 为非LTS版本，eclipse-temurin 只发布 JDK 镜像，无独立 JRE 镜像）
FROM eclipse-temurin:25-jdk
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080

# JAVA_TOOL_OPTIONS 由 K8s Deployment env 注入，JVM 自动读取
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- [ ] **Step 2: 本地测试 Docker 构建**

```bash
cd app && docker build -t java-experiment:latest .
```

预期：`Successfully tagged java-experiment:latest`，镜像大小约 200-300 MB。

- [ ] **Step 3: 验证容器能启动**

```bash
docker run --rm -d -p 8080:8080 --name test-app java-experiment:latest
sleep 8
curl -s http://localhost:8080/actuator/health
docker stop test-app
```

预期：返回 `{"status":"UP",...}`。

- [ ] **Step 4: 验证 JAVA_TOOL_OPTIONS 生效**

```bash
docker run --rm -d -p 8080:8080 \
  -e JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75" \
  --memory=512m \
  --name test-app java-experiment:latest
sleep 8
# 堆上限应为 512 * 0.75 ≈ 384MB = ~402653184 bytes
curl -s "http://localhost:8080/actuator/metrics/jvm.memory.max?tag=area:heap"
docker stop test-app
```

预期：`measurements[0].value` 约为 `402653184`（384MB）。

- [ ] **Step 5: Commit**

```bash
git add app/Dockerfile
git commit -m "feat: add multi-stage Dockerfile for Java 25 runtime"
```

---

## Chunk 2: kind Cluster Setup

### Task 5: kind cluster configuration

**Files:**
- Create: `k8s/kind-config.yaml`
- Create: `scripts/setup-cluster.sh`

- [ ] **Step 1: 创建 kind 集群配置**

创建 `k8s/kind-config.yaml`：

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: java-experiment
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

- [ ] **Step 2: 创建集群安装脚本**

创建 `scripts/setup-cluster.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== [1/4] 创建 kind 集群 ==="
kind create cluster --config k8s/kind-config.yaml
kubectl cluster-info --context kind-java-experiment

echo "=== [2/4] 构建 Docker 镜像 ==="
docker build -t java-experiment:latest app/

echo "=== [3/4] 加载镜像到 kind 集群 ==="
kind load docker-image java-experiment:latest --name java-experiment

echo "=== [4/4] 验证镜像已加载 ==="
kubectl get nodes
docker exec java-experiment-worker crictl images | grep java-experiment

echo ""
echo "集群已就绪。运行实验："
echo "  bash scripts/run-scenario.sh 01-default"
```

- [ ] **Step 3: 赋予执行权限**

```bash
chmod +x scripts/setup-cluster.sh
```

- [ ] **Step 4: 运行安装脚本**

```bash
bash scripts/setup-cluster.sh
```

预期：输出 `集群已就绪`，`kubectl get nodes` 显示 3 个节点（1 control-plane + 2 workers）均为 `Ready`。

- [ ] **Step 5: Commit**

```bash
git add k8s/kind-config.yaml scripts/setup-cluster.sh
git commit -m "feat: add kind cluster config and setup script"
```

---

## Chunk 3: Kubernetes Scenario Manifests

### Task 6: Scenario Deployment YAMLs

每个 YAML 包含一个 Deployment + 一个 ClusterIP Service。JVM 参数通过 `JAVA_TOOL_OPTIONS` 传入。

**Files:**
- Create: `k8s/scenarios/01-default.yaml` 至 `06-pod-sizing-large.yaml`

- [ ] **Step 1: 创建场景 01 — 默认配置（无 JVM 参数）**

创建 `k8s/scenarios/01-default.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment
  labels:
    scenario: "01-default"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: java-experiment
  template:
    metadata:
      labels:
        app: java-experiment
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: ""
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment
spec:
  selector:
    app: java-experiment
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 2: 创建场景 02 — 修复堆比例**

创建 `k8s/scenarios/02-heap-fixed.yaml`（与 01 相同，仅修改 `JAVA_TOOL_OPTIONS`）：

```yaml
# 与 01-default.yaml 相同结构，仅以下字段不同：
# env[0].value: "-XX:MaxRAMPercentage=75"
# labels.scenario: "02-heap-fixed"
```

完整文件 `k8s/scenarios/02-heap-fixed.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment
  labels:
    scenario: "02-heap-fixed"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: java-experiment
  template:
    metadata:
      labels:
        app: java-experiment
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:MaxRAMPercentage=75"
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment
spec:
  selector:
    app: java-experiment
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 3: 创建场景 03 — SerialGC**

创建 `k8s/scenarios/03-serial-gc.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment
  labels:
    scenario: "03-serial-gc"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: java-experiment
  template:
    metadata:
      labels:
        app: java-experiment
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:+UseSerialGC -XX:MaxRAMPercentage=75"
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment
spec:
  selector:
    app: java-experiment
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 4: 创建场景 04 — G1GC**

创建 `k8s/scenarios/04-g1gc.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment
  labels:
    scenario: "04-g1gc"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: java-experiment
  template:
    metadata:
      labels:
        app: java-experiment
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:+UseG1GC -XX:MaxRAMPercentage=75"
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment
spec:
  selector:
    app: java-experiment
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 5: 创建场景 05 — CPU 节流**

创建 `k8s/scenarios/05-cpu-throttle.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment
  labels:
    scenario: "05-cpu-throttle"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: java-experiment
  template:
    metadata:
      labels:
        app: java-experiment
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:+UseG1GC -XX:MaxRAMPercentage=75"
          resources:
            requests:
              memory: "512Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment
spec:
  selector:
    app: java-experiment
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 6: 创建场景 06 — Pod 规格对比（小副本）**

创建 `k8s/scenarios/06-pod-sizing-small.yaml`（3 副本 × 0.25c，独立命名）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment-small
  labels:
    scenario: "06-pod-sizing-small"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: java-experiment-small
  template:
    metadata:
      labels:
        app: java-experiment-small
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:+UseG1GC -XX:MaxRAMPercentage=75"
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "250m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment-small
spec:
  selector:
    app: java-experiment-small
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 7: 创建场景 06 — Pod 规格对比（大副本）**

创建 `k8s/scenarios/06-pod-sizing-large.yaml`（1 副本 × 0.75c，独立命名）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-experiment-large
  labels:
    scenario: "06-pod-sizing-large"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: java-experiment-large
  template:
    metadata:
      labels:
        app: java-experiment-large
    spec:
      containers:
        - name: app
          image: java-experiment:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:+UseG1GC -XX:MaxRAMPercentage=75"
          resources:
            requests:
              memory: "512Mi"
              cpu: "750m"
            limits:
              memory: "512Mi"
              cpu: "750m"
---
apiVersion: v1
kind: Service
metadata:
  name: java-experiment-large
spec:
  selector:
    app: java-experiment-large
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 8: 验证所有 YAML 语法正确**

```bash
for f in k8s/scenarios/*.yaml; do
  kubectl apply --dry-run=client -f $f && echo "OK: $f"
done
```

预期：每个文件输出 `deployment.apps/.../created (dry run)` 和 `service/.../created (dry run)`，无报错。

- [ ] **Step 9: Commit**

```bash
git add k8s/scenarios/
git commit -m "feat: add 6 experiment scenario K8s manifests"
```

---

## Chunk 4: k6 Load Test Script

### Task 7: k6 load-test.js

**Files:**
- Create: `k6/load-test.js`

- [ ] **Step 1: 创建 k6 脚本**

创建 `k6/load-test.js`：

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

// BASE_URL 通过环境变量注入，默认 localhost:8080
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  vus: 10,        // 10 个并发虚拟用户
  duration: '60s', // 每个场景跑 60 秒
};

export default function () {
  const rand = Math.random();

  if (rand < 0.6) {
    // 60% 请求：分配内存触发 GC（每次 30MB 的短生命周期对象）
    const res = http.get(`${BASE_URL}/stress/memory?mb=30`);
    check(res, {
      'memory stress 200': (r) => r.status === 200,
    });
  } else {
    // 40% 请求：CPU 压力（每次 1 秒计算）
    const res = http.get(`${BASE_URL}/stress/cpu?seconds=1`);
    check(res, {
      'cpu stress 200': (r) => r.status === 200,
    });
  }

  sleep(0.1);
}
```

- [ ] **Step 2: 验证 k6 脚本语法**

```bash
k6 inspect k6/load-test.js
```

预期：输出脚本元数据（vus, duration），无报错。

- [ ] **Step 3: Commit**

```bash
git add k6/load-test.js
git commit -m "feat: add k6 load test script for 60s mixed memory/CPU stress"
```

---

## Chunk 5: Automation Scripts

### Task 8: collect-metrics.sh

**Files:**
- Create: `scripts/collect-metrics.sh`

- [ ] **Step 1: 创建指标采集脚本**

创建 `scripts/collect-metrics.sh`：

```bash
#!/usr/bin/env bash
# 从运行中的 Pod 采集 JVM 指标
# 用法: bash scripts/collect-metrics.sh [deployment-name]
set -euo pipefail

DEPLOYMENT=${1:-java-experiment}

echo ""
echo "======================================"
echo " JVM Metrics: ${DEPLOYMENT}"
echo "======================================"

POD=$(kubectl get pod -l app=${DEPLOYMENT} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "ERROR: 找不到 app=${DEPLOYMENT} 的 Pod"
  exit 1
fi

echo "Pod: $POD"
echo ""

# 1. 堆最大值（验证 25% vs 75%）
echo "--- Heap Max ---"
HEAP_MAX=$(kubectl exec "$POD" -- curl -s "http://localhost:8080/actuator/metrics/jvm.memory.max?tag=area:heap" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['measurements'][0]['value'])")
HEAP_MAX_MB=$(python3 -c "print(round(${HEAP_MAX}/1024/1024, 1))")
echo "jvm.memory.max (heap) = ${HEAP_MAX} bytes = ${HEAP_MAX_MB} MB"

# 2. 堆已使用
echo ""
echo "--- Heap Used ---"
HEAP_USED=$(kubectl exec "$POD" -- curl -s "http://localhost:8080/actuator/metrics/jvm.memory.used?tag=area:heap" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['measurements'][0]['value'])")
HEAP_USED_MB=$(python3 -c "print(round(${HEAP_USED}/1024/1024, 1))")
echo "jvm.memory.used (heap) = ${HEAP_USED} bytes = ${HEAP_USED_MB} MB"

# 3. GC 停顿统计
echo ""
echo "--- GC Pause ---"
kubectl exec "$POD" -- curl -s "http://localhost:8080/actuator/metrics/jvm.gc.pause" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('GC Pause measurements:')
for m in d.get('measurements', []):
    print(f'  {m[\"statistic\"]}: {m[\"value\"]}')
"

# 4. Pod CPU/内存（需要 metrics-server，kind 默认无，故提示）
echo ""
echo "--- Pod Resources (kubectl top) ---"
kubectl top pod "$POD" 2>/dev/null || echo "  (metrics-server 未安装，跳过 kubectl top)"

echo ""
echo "======================================"
```

- [ ] **Step 2: 赋予执行权限**

```bash
chmod +x scripts/collect-metrics.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/collect-metrics.sh
git commit -m "feat: add JVM metrics collection script"
```

---

### Task 9: run-scenario.sh

**Files:**
- Create: `scripts/run-scenario.sh`

- [ ] **Step 1: 创建场景运行脚本**

创建 `scripts/run-scenario.sh`：

```bash
#!/usr/bin/env bash
# 运行单个实验场景
# 用法: bash scripts/run-scenario.sh <scenario-name>
# 示例: bash scripts/run-scenario.sh 01-default
set -euo pipefail

SCENARIO=${1:?"用法: $0 <scenario-name>，例如: 01-default"}
RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="${RESULTS_DIR}/${TIMESTAMP}-${SCENARIO}.txt"

# 函数定义必须在调用前（bash 要求）
# 场景 06 Pod 规格对比
run_pod_sizing_comparison() {
  echo "[1/6] 清理旧 Deployment (如存在)..."
  kubectl delete deployment java-experiment --ignore-not-found=true
  kubectl delete service java-experiment --ignore-not-found=true

  echo "[2/6] 部署小副本（3 × 0.25c）..."
  kubectl apply -f "k8s/scenarios/06-pod-sizing-small.yaml"
  kubectl rollout status deployment/java-experiment-small --timeout=120s
  sleep 15

  echo "[3/6] k6 压测小副本..." | tee -a "$OUTPUT_FILE"
  kubectl port-forward service/java-experiment-small 8080:8080 &>/dev/null &
  PF_PID=$!
  sleep 3
  k6 run -e BASE_URL=http://localhost:8080 k6/load-test.js 2>&1 | tee -a "${RESULTS_DIR}/${TIMESTAMP}-06-small.txt"
  kill $PF_PID 2>/dev/null || true

  echo "[4/6] 部署大副本（1 × 0.75c）..."
  kubectl apply -f "k8s/scenarios/06-pod-sizing-large.yaml"
  kubectl rollout status deployment/java-experiment-large --timeout=120s
  sleep 15

  echo "[5/6] k6 压测大副本..." | tee -a "$OUTPUT_FILE"
  kubectl port-forward service/java-experiment-large 8081:8080 &>/dev/null &
  PF_PID=$!
  sleep 3
  k6 run -e BASE_URL=http://localhost:8081 k6/load-test.js 2>&1 | tee -a "${RESULTS_DIR}/${TIMESTAMP}-06-large.txt"
  kill $PF_PID 2>/dev/null || true

  echo "[6/6] 对比结果:"
  echo "  小副本结果: ${RESULTS_DIR}/${TIMESTAMP}-06-small.txt"
  echo "  大副本结果: ${RESULTS_DIR}/${TIMESTAMP}-06-large.txt"
  echo "  关注指标：http_reqs（总请求数）和 http_req_duration p95"
}

echo "======================================"
echo " 场景: ${SCENARIO}"
echo " 结果文件: ${OUTPUT_FILE}"
echo "======================================"

# 场景 06 需要特殊处理（两个独立 Deployment）
if [[ "$SCENARIO" == "06-pod-sizing" ]]; then
  run_pod_sizing_comparison
  exit 0
fi

# 1. 部署场景
echo ""
echo "[1/5] 应用 Deployment..."
kubectl apply -f "k8s/scenarios/${SCENARIO}.yaml"

# 2. 等待 Rollout 完成
echo "[2/5] 等待 Pod 就绪..."
kubectl rollout status deployment/java-experiment --timeout=120s

# 3. 等待 JVM 预热
echo "[3/5] 等待 JVM 预热 (15s)..."
sleep 15

# 4. 采集初始 JVM 指标（压测前）
echo "[4/5] 采集初始 JVM 指标..." | tee -a "$OUTPUT_FILE"
bash scripts/collect-metrics.sh java-experiment 2>&1 | tee -a "$OUTPUT_FILE"

# 5. 启动 port-forward，运行 k6，结束后关闭 port-forward
echo "[5/5] 运行 k6 压测 (60s)..." | tee -a "$OUTPUT_FILE"
kubectl port-forward service/java-experiment 8080:8080 &>/dev/null &
PF_PID=$!
sleep 3  # 等待 port-forward 建立

k6 run -e BASE_URL=http://localhost:8080 k6/load-test.js 2>&1 | tee -a "$OUTPUT_FILE"

kill $PF_PID 2>/dev/null || true

# 6. 采集压测后 JVM 指标
echo "" | tee -a "$OUTPUT_FILE"
echo "--- 压测后 JVM 指标 ---" | tee -a "$OUTPUT_FILE"
bash scripts/collect-metrics.sh java-experiment 2>&1 | tee -a "$OUTPUT_FILE"

echo ""
echo "完成！结果已保存到: ${OUTPUT_FILE}"
echo "======================================"
```

- [ ] **Step 2: 赋予执行权限**

```bash
chmod +x scripts/run-scenario.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/run-scenario.sh
git commit -m "feat: add run-scenario automation script"
```

---

## Chunk 6: End-to-End Validation

### Task 10: 验证完整实验流程

- [ ] **Step 1: 确认所有文件已存在**

```bash
ls app/Dockerfile app/src/ k8s/kind-config.yaml k8s/scenarios/ k6/load-test.js scripts/
```

- [ ] **Step 2: 运行场景 01（基准，默认配置）**

```bash
bash scripts/run-scenario.sh 01-default
```

预期：k6 完成 60s 压测，输出 `http_reqs`、`http_req_duration`。指标文件中 heap max ≈ **128 MB**。

- [ ] **Step 3: 运行场景 02（修复堆）**

```bash
bash scripts/run-scenario.sh 02-heap-fixed
```

预期：heap max ≈ **384 MB**，与场景 01 对比增加约 3 倍。

- [ ] **Step 4: 对比验证堆配置问题（实验核心验证）**

```bash
echo "=== 场景01 堆上限 ==="
grep "jvm.memory.max" results/*01-default*.txt | head -3

echo "=== 场景02 堆上限 ==="
grep "jvm.memory.max" results/*02-heap-fixed*.txt | head -3
```

预期：两个数值差异约 3 倍（128MB vs 384MB）——**这就是文章核心发现的可视化证明**。

- [ ] **Step 5: 依次运行剩余场景**

```bash
bash scripts/run-scenario.sh 03-serial-gc
bash scripts/run-scenario.sh 04-g1gc
bash scripts/run-scenario.sh 05-cpu-throttle
bash scripts/run-scenario.sh 06-pod-sizing
```

- [ ] **Step 6: 汇总对比（从 results/ 目录手动查看）**

```bash
ls -la results/
# 查看各场景 k6 吞吐量对比
grep "http_reqs" results/*.txt
# 查看各场景 p95 延迟对比
grep "http_req_duration.*p(95)" results/*.txt
```

- [ ] **Step 7: 清理集群（实验结束后）**

```bash
kind delete cluster --name java-experiment
```

---

## 实验预期数据摘要

| 对比 | 关键指标 | 预期差异 |
|------|----------|----------|
| 场景01 vs 02 | `jvm.memory.max (heap)` | 128 MB → 384 MB（+3x） |
| 场景03 vs 04 | `jvm.gc.pause MAX` | SerialGC 高停顿 vs G1GC 低停顿 |
| 场景04 vs 05 | k6 `http_req_duration p95` | CPU节流后延迟 5-10x 上升 |
| 场景06-small vs large | k6 `http_reqs`（总吞吐） | 大副本 RPS 高于小副本之和 |
