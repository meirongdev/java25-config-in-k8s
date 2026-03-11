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
