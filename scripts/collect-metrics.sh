#!/usr/bin/env bash
# 从运行中的 Pod 采集 JVM 指标
# 用法: bash scripts/collect-metrics.sh [deployment-name] [namespace]
set -euo pipefail

DEPLOYMENT=${1:-java-experiment}
NAMESPACE=${2:-default}

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

# 使用 kubectl get --raw 采集指标，不需要容器内有 curl
# 基础代理路径: /api/v1/namespaces/{NAMESPACE}/pods/{POD}:8080/proxy/actuator/metrics/{METRIC}
ACTUATOR_BASE_URL="/api/v1/namespaces/${NAMESPACE}/pods/${POD}:8080/proxy/actuator/metrics"

get_metric() {
  local metric_name=$1
  local tags=${2:-""}
  local url="${ACTUATOR_BASE_URL}/${metric_name}"
  if [ -n "$tags" ]; then
    url="${url}?tag=${tags}"
  fi
  kubectl get --raw "$url" 2>/dev/null || echo ""
}

# 1. 堆最大值
echo "--- Heap Max ---"
HEAP_MAX_JSON=$(get_metric "jvm.memory.max" "area:heap")
if [ -n "$HEAP_MAX_JSON" ]; then
  HEAP_MAX=$(echo "$HEAP_MAX_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['measurements'][0]['value'])")
  HEAP_MAX_MB=$(python3 -c "print(round(${HEAP_MAX}/1024/1024, 1))")
  echo "jvm.memory.max (heap) = ${HEAP_MAX} bytes = ${HEAP_MAX_MB} MB"
else
  echo "无法获取 jvm.memory.max"
fi

# 2. 堆已使用
echo ""
echo "--- Heap Used ---"
HEAP_USED_JSON=$(get_metric "jvm.memory.used" "area:heap")
if [ -n "$HEAP_USED_JSON" ]; then
  HEAP_USED=$(echo "$HEAP_USED_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['measurements'][0]['value'])")
  HEAP_USED_MB=$(python3 -c "print(round(${HEAP_USED}/1024/1024, 1))")
  echo "jvm.memory.used (heap) = ${HEAP_USED} bytes = ${HEAP_USED_MB} MB"
else
  echo "无法获取 jvm.memory.used"
fi

# 3. GC 停顿统计
echo ""
echo "--- GC Pause ---"
GC_PAUSE_JSON=$(get_metric "jvm.gc.pause")
if [ -n "$GC_PAUSE_JSON" ]; then
  echo "$GC_PAUSE_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('GC Pause measurements:')
for m in d.get('measurements', []):
    print(f'  {m[\"statistic\"]}: {m[\"value\"]}')
"
else
  echo "无法获取 jvm.gc.pause"
fi

# 4. Pod CPU/内存
echo ""
echo "--- Pod Resources (kubectl top) ---"
kubectl top pod "$POD" 2>/dev/null || echo "  (metrics-server 未安装，跳过 kubectl top)"

echo ""
echo "======================================"
