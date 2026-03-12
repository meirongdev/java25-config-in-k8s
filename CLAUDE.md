# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Run unit tests (from app/ directory)
cd app && mvn test

# Run a single test class
cd app && mvn test -Dtest=StressControllerTest

# Build Docker image (from repo root)
docker build -t java-experiment:latest app/
```

## Cluster Setup & Experiment Execution

```bash
# First-time setup: creates kind cluster, builds and loads Docker image
bash scripts/setup-cluster.sh

# Run a single scenario (deploys, warms up 15s, collects JVM metrics, runs k6, collects post-metrics)
bash scripts/run-scenario.sh 01-default
bash scripts/run-scenario.sh 06-pod-sizing   # special: runs both small and large pods

# Run all 14 scenarios sequentially (takes ~30+ min)
bash scripts/run-all-scenarios.sh
```

## Architecture

**The experiment loop:** `k8s/scenarios/<N>-<name>.yaml` → `kubectl apply` → `kubectl port-forward` → `k6/load-test.js` → `scripts/collect-metrics.sh` (Spring Actuator via `kubectl get --raw`).

**JVM parameters are injected via `JAVA_TOOL_OPTIONS`** environment variable in each scenario YAML. The Dockerfile has no JVM flags — all GC/heap config comes from Kubernetes.

**Spring Boot app** (`app/src/main/java/dev/meirong/k8sexperiment/`):
- `StressController` — two endpoints: `GET /stress/memory?mb=30` (allocates short-lived byte arrays) and `GET /stress/cpu?seconds=0.3` (prime number computation)
- `StressService` — implements the actual allocation and CPU work
- Exposes Spring Actuator at `/actuator/metrics` for JVM metric collection

**k6 load profile** (`k6/load-test.js`): 10 VUs × 60s, 60% memory requests (30MB garbage), 40% CPU requests (0.3s prime calc), 0.1s sleep between iterations.

**Scenario numbering:**
- 01–07: baseline scenarios (heap, GC type, CPU throttle, pod sizing)
- 08–11: G1GC vs ZGC at 2c/2g and 4c/4g
- 12–14: ZGC Generational (`-XX:+ZGenerational`) at 1c/2c/4c
- Scenario 06 is special: deploys two separate Deployments (`java-experiment-small` / `java-experiment-large`) compared side-by-side

**Metrics collection** (`scripts/collect-metrics.sh`): uses `kubectl get --raw` to call Actuator without needing curl inside the container. Reads `jvm.memory.max`, `jvm.memory.used`, and `jvm.gc.pause` (COUNT, MAX, TOTAL_TIME).

**Results** are saved to `results/<timestamp>-<scenario>.txt` (single scenario) or `results/<name>.txt` + `results/<name>-k6.json` (batch run).

## Adding a New Scenario

1. Create `k8s/scenarios/<N>-<name>.yaml` — set `JAVA_TOOL_OPTIONS` env var for JVM flags, adjust `resources.limits`
2. Add an entry to `scripts/run-all-scenarios.sh` calling `run_scenario "<N>-<name>" "k8s/scenarios/<N>-<name>.yaml" "java-experiment" "java-experiment"`
3. After running, add results to the relevant report in `results/`
