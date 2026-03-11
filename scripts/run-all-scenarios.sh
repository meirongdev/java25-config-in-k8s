#!/usr/bin/env bash
# 运行所有实验场景并收集数据（v2: 1c/1Gi 基准，无显式 GC 类型）
set -euo pipefail

CONTEXT="kind-java-experiment"
RESULTS="results"
METRICS_PORT=19080
K6_PORT=18080

mkdir -p "$RESULTS"

start_pf() {
  local SVC=$1 HOST_PORT=$2
  kubectl port-forward "service/$SVC" "${HOST_PORT}:8080" --context "$CONTEXT" &>/dev/null &
  echo $!
}

collect_jvm() {
  local OUT=$1
  local BASE="http://localhost:${METRICS_PORT}"

  HEAP_MAX=$(curl -sf "${BASE}/actuator/metrics/jvm.memory.max?tag=area:heap" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['measurements'][0]['value']))" 2>/dev/null || echo "0")
  HEAP_USED=$(curl -sf "${BASE}/actuator/metrics/jvm.memory.used?tag=area:heap" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['measurements'][0]['value']))" 2>/dev/null || echo "0")
  GC_COUNT=$(curl -sf "${BASE}/actuator/metrics/jvm.gc.pause" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); ms=[m for m in d.get('measurements',[]) if m['statistic']=='COUNT']; print(int(ms[0]['value']) if ms else 0)" 2>/dev/null || echo "0")
  GC_MAX_S=$(curl -sf "${BASE}/actuator/metrics/jvm.gc.pause" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); ms=[m for m in d.get('measurements',[]) if m['statistic']=='MAX']; print(ms[0]['value'] if ms else 0)" 2>/dev/null || echo "0")
  GC_TOTAL_S=$(curl -sf "${BASE}/actuator/metrics/jvm.gc.pause" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); ms=[m for m in d.get('measurements',[]) if m['statistic']=='TOTAL_TIME']; print(ms[0]['value'] if ms else 0)" 2>/dev/null || echo "0")

  HEAP_MAX_MB=$(python3 -c "print(round($HEAP_MAX/1024/1024,1))")
  HEAP_USED_MB=$(python3 -c "print(round($HEAP_USED/1024/1024,1))")
  GC_MAX_MS=$(python3 -c "print(round(float('$GC_MAX_S')*1000,2))")
  GC_TOTAL_MS=$(python3 -c "print(round(float('$GC_TOTAL_S')*1000,2))")

  echo "  heap_max=${HEAP_MAX_MB}MB  heap_used=${HEAP_USED_MB}MB  gc_count=${GC_COUNT}  gc_max=${GC_MAX_MS}ms  gc_total=${GC_TOTAL_MS}ms" | tee -a "$OUT"
  echo "METRICS heap_max_mb=$HEAP_MAX_MB heap_used_mb=$HEAP_USED_MB gc_count=$GC_COUNT gc_max_ms=$GC_MAX_MS gc_total_ms=$GC_TOTAL_MS" >> "$OUT"
}

run_scenario() {
  local NAME=$1 YAML=$2 DEPLOY=$3 SVC=$4
  local OUT="$RESULTS/${NAME}.txt"
  : > "$OUT"

  echo "======================================" | tee -a "$OUT"
  echo " SCENARIO: $NAME  $(date)" | tee -a "$OUT"
  echo "======================================" | tee -a "$OUT"

  kubectl apply -f "$YAML" --context "$CONTEXT" 2>&1 | tail -2 | tee -a "$OUT"
  kubectl rollout status "deployment/$DEPLOY" --timeout=180s --context "$CONTEXT" | tee -a "$OUT"
  echo "Warming up JVM (20s)..." | tee -a "$OUT"
  sleep 20

  PF_METRICS=$(start_pf "$SVC" "$METRICS_PORT"); sleep 2

  echo "--- Pre-load JVM metrics ---" | tee -a "$OUT"
  collect_jvm "$OUT"
  kill "$PF_METRICS" 2>/dev/null || true; sleep 1

  PF_K6=$(start_pf "$SVC" "$K6_PORT"); sleep 2

  echo "--- k6 load test (60s, 10 VUs) ---" | tee -a "$OUT"
  k6 run \
    -e BASE_URL="http://localhost:${K6_PORT}" \
    --summary-export="$RESULTS/${NAME}-k6.json" \
    k6/load-test.js 2>&1 | tee -a "$OUT"

  kill "$PF_K6" 2>/dev/null || true; sleep 1

  PF_METRICS=$(start_pf "$SVC" "$METRICS_PORT"); sleep 2

  echo "--- Post-load JVM metrics ---" | tee -a "$OUT"
  collect_jvm "$OUT"
  kill "$PF_METRICS" 2>/dev/null || true

  kubectl delete -f "$YAML" --context "$CONTEXT" 2>&1 | tail -2 | tee -a "$OUT"
  sleep 10
  echo "Done: $NAME" | tee -a "$OUT"
}

echo "=== Java 25 K8s Experiment v2 - $(date) ===" | tee "$RESULTS/summary.txt"

run_scenario "01-default"      "k8s/scenarios/01-default.yaml"           "java-experiment"       "java-experiment"
run_scenario "02-heap-fixed"   "k8s/scenarios/02-heap-fixed.yaml"        "java-experiment"       "java-experiment"
run_scenario "03-cpu-throttle" "k8s/scenarios/05-cpu-throttle.yaml"      "java-experiment"       "java-experiment"
run_scenario "04-pod-small"    "k8s/scenarios/06-pod-sizing-small.yaml"  "java-experiment-small" "java-experiment-small"
run_scenario "04-pod-large"    "k8s/scenarios/06-pod-sizing-large.yaml"  "java-experiment-large" "java-experiment-large"

echo "" | tee -a "$RESULTS/summary.txt"
echo "=== All scenarios complete ===" | tee -a "$RESULTS/summary.txt"
