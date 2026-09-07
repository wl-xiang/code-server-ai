#!/usr/bin/env bash
# ============================================================
# code-server-ai 跨架构构建脚本 (amd64 原生 / arm64 QEMU 模拟)
#
# 用法:
#   ./buildx.sh            # 等同于 amd64
#   ./buildx.sh amd64      # 只构建 amd64 (原生, 快)
#   ./buildx.sh arm64      # 只构建 arm64 (QEMU 模拟, 30-60 分钟起, 勿中断)
#   ./buildx.sh all        # 两个架构都构建并各导出一个 tgz
#
# 产物 (repo-deploy-packager 命名规范):
#   results/code-server-image/code-server-image_docker-images_linux-amd64.tgz
#   results/code-server-image/code-server-image_docker-images_linux-arm64.tgz
#
# 可选构建参数 (环境变量传入, 留空 = 自动取最新):
#   NODE_VERSION=24.13.1 GO_VERSION=1.27.1 APT_MIRROR=mirrors.aliyun.com ./buildx.sh all
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="code-server-ai"
RESULT_DIR="results/code-server-image"
TARGET="${1:-amd64}"   # amd64 | arm64 | all

log() { echo "[buildx] $*"; }
die() { echo "[buildx][ERROR] $*" >&2; exit 1; }

# ---------- 0. buildx 插件检查 (Windows Docker Desktop 自带但可能未注册) ----------
if ! docker buildx version >/dev/null 2>&1; then
    DESKTOP_PLUGIN="/c/Program Files/Docker/Docker/resources/cli-plugins/docker-buildx.exe"
    if [ -f "$DESKTOP_PLUGIN" ]; then
        log "buildx 插件未注册, 从 Docker Desktop 复制到用户插件目录..."
        mkdir -p ~/.docker/cli-plugins
        cp "$DESKTOP_PLUGIN" ~/.docker/cli-plugins/
    fi
    docker buildx version >/dev/null 2>&1 || die "docker buildx 不可用, 请先安装 buildx 插件"
fi
log "buildx: $(docker buildx version | awk '{print $NF}')"

# ---------- 1. QEMU binfmt 模拟环境 (arm64 必需, 预检失败自动安装) ----------
# NOTE: 预检用 alpine:latest 试跑 arm64 —— 若报的是"拉取失败"只是 Hub 网络不通,
#       并不代表 binfmt 坏了; 而安装 tonistiigi/binfmt 同样要联网, Hub 不可达时
#       先解决网络再跑本脚本
if [ "$TARGET" != "amd64" ]; then
    log "预检 QEMU arm64 模拟..."
    if ! docker run --rm --platform linux/arm64 alpine:latest uname -m 2>/dev/null | grep -q aarch64; then
        log "QEMU binfmt 未就绪 (或 alpine 拉取失败), 尝试安装 tonistiigi/binfmt (arm64)..."
        docker run --privileged --rm tonistiigi/binfmt --install arm64
        docker run --rm --platform linux/arm64 alpine:latest uname -m | grep -q aarch64 \
            || die "binfmt 安装后模拟仍不可用: 若为拉取失败请检查网络, 否则重启 Docker Desktop 后重试"
    fi
    log "QEMU arm64 模拟就绪"
fi

# ---------- 2. 构建器选择 ----------
# 优先 desktop-linux (docker 驱动, 与 daemon 共享网络/镜像存储);
# 避开 multiarch 之类 container 驱动构建器 (曾在容器内拉镜像遇网络问题)
if docker buildx inspect desktop-linux >/dev/null 2>&1; then
    BUILDER="desktop-linux"
else
    BUILDER="default"
fi
log "使用构建器: $BUILDER"

# ---------- 3. 可选构建参数透传 ----------
BUILD_ARGS=()
[ -n "${NODE_VERSION:-}" ] && BUILD_ARGS+=(--build-arg "NODE_VERSION=${NODE_VERSION}")
[ -n "${GO_VERSION:-}" ]   && BUILD_ARGS+=(--build-arg "GO_VERSION=${GO_VERSION}")
[ -n "${APT_MIRROR:-}" ]   && BUILD_ARGS+=(--build-arg "APT_MIRROR=${APT_MIRROR}")
# Docker Hub 不通时切国内镜像: BASE_IMAGE=docker.m.daocloud.io/codercom/code-server:latest ./buildx.sh arm64
[ -n "${BASE_IMAGE:-}" ]   && BUILD_ARGS+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")

mkdir -p "$RESULT_DIR"

# ---------- 4. 按架构构建 + 导出 ----------
build_one() {
    local platform="$1"   # amd64 | arm64
    local tag
    if [ "$platform" = "amd64" ]; then tag="${IMAGE}:latest"; else tag="${IMAGE}:arm64"; fi

    if [ "$platform" = "arm64" ]; then
        log "===== 构建 linux/arm64 (QEMU 模拟, apt/编译环节较慢, 预计 30-60 分钟, 请勿中断) ====="
    else
        log "===== 构建 linux/amd64 (原生) ====="
    fi

    docker buildx build --builder "$BUILDER" \
        --platform "linux/${platform}" \
        --load -t "$tag" \
        "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" \
        .

    # 构建后自检: 目标架构下 opencode 可执行 (同时验证 QEMU 模拟链路)
    # NOTE: 显式 --platform 必须带上 —— amd64 宿主机跑 arm64 镜像时若省略,
    #       docker 会按宿主架构解释并产生 WARNING, 依赖隐式行为不可靠
    log "自检 ${tag} ..."
    docker run --rm --platform "linux/${platform}" --entrypoint sh "$tag" \
        -c 'uname -m && opencode --version | head -1 && node -v && python3 --version && go version'

    local out="${RESULT_DIR}/code-server-image_docker-images_linux-${platform}.tgz"
    log "导出 ${out} ..."
    docker save "$tag" | gzip > "$out"
    sha256sum "$out" | tee "${RESULT_DIR}/code-server-image_sha256_linux-${platform}.txt"
    log "完成: $out ($(du -h "$out" | cut -f1))"
}

case "$TARGET" in
    amd64) build_one amd64 ;;
    arm64) build_one arm64 ;;
    all)   build_one amd64; build_one arm64 ;;
    *) die "用法: $0 [amd64|arm64|all]" ;;
esac

# ---------- 5. 部署提示 ----------
log "============================================================"
log "服务器部署 (对应架构的 tar 包):"
log "  docker load -i code-server-image_docker-images_linux-<arch>.tgz"
log "  arm64 包镜像 tag 为 ${IMAGE}:arm64, 如 compose 用 latest 请先:"
log "    docker tag ${IMAGE}:arm64 ${IMAGE}:latest"
log "  然后: docker compose up -d"
log "============================================================"
