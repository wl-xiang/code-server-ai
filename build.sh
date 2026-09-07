#!/usr/bin/env bash
# 构建 amd64 镜像并导出离线 tar 包
# 用法: ./build.sh        (在装好 Docker 的机器上执行)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_NAME=code-server-ai
TAG=latest

echo "==> [1/2] 构建镜像 ${IMAGE_NAME}:${TAG} (linux/amd64) ..."
docker build --platform linux/amd64 -t ${IMAGE_NAME}:${TAG} .

echo "==> [2/2] 导出离线包 code-server-ai_amd64.tar ..."
docker save -o code-server-ai_amd64.tar ${IMAGE_NAME}:${TAG}

echo "==> 完成: $(ls -lh code-server-ai_amd64.tar | awk '{print $5, $9}')"
echo "服务器导入: docker load -i code-server-ai_amd64.tar"
