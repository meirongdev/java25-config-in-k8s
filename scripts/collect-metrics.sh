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
