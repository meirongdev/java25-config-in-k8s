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
