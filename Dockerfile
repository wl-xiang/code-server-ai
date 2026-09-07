# ============================================================
# code-server AI 开发环境镜像 (linux/amd64 + linux/arm64)
# Base: codercom/code-server (官方发布镜像, Ubuntu)
# Source repo: https://github.com/coder/code-server
#
# 跨架构构建: ./buildx.sh (自动准备 QEMU binfmt 模拟 + 按架构构建导出)
# amd64 本机原生构建; arm64 走 QEMU 模拟, 构建速度慢属正常现象
# ============================================================
# 基础镜像 (默认官方 codercom/code-server:latest; Hub 网络不通时可切换国内镜像:
# 如 docker.m.daocloud.io/codercom/code-server:latest, 需为多架构镜像)
ARG BASE_IMAGE=codercom/code-server:latest
FROM ${BASE_IMAGE}

USER root

# ---------- 构建参数 ----------
# 目标架构: buildx 自动注入 amd64/arm64 (注意: 不能给默认值, 否则默认值会
# 覆盖 buildx 注入的真实架构!); 留空时下方逻辑按 amd64/x86_64 处理
ARG TARGETARCH
# apt 镜像源 (留空 = 官方源 deb.debian.org; 网络不通时再改如 mirrors.aliyun.com)
ARG APT_MIRROR=
# Node 版本: 留空 = 构建时自动获取 v24 LTS 最新版 (如需固定: 24.13.1)
ARG NODE_VERSION=
# Python 3.14 预编译包完整下载地址: 留空 = 从 GitHub 自动获取最新 3.14.x
ARG PYTHON_URL=
# Go 版本: 留空 = 构建时自动获取最新稳定版
ARG GO_VERSION=
# Oracle Instant Client ARM64 直链 (x64 用官方 latest 别名无需配置;
# ARM64 无别名, 目录号随 Oracle 发版会变, 失效时去
# https://www.oracle.com/database/technologies/instant-client/linux-arm-aarch64-downloads.html 取新链接)
ARG ORACLE_ARM64_URL=https://download.oracle.com/otn_software/linux/instantclient/2326300/instantclient-basic-linux.arm64-23.26.3.0.0.zip

# ---------- 1. 系统依赖 ----------
# jq / ripgrep(rg) / yq(下面单独装) / fzf 等常用工具
# libaio1: Oracle Instant Client 运行时依赖
RUN if [ -n "$APT_MIRROR" ]; then \
        grep -rl "archive.ubuntu.com\|security.ubuntu.com\|deb.debian.org" /etc/apt 2>/dev/null | \
            xargs -r sed -i "s|archive.ubuntu.com|$APT_MIRROR|g; s|security.ubuntu.com|$APT_MIRROR|g; s|deb.debian.org|$APT_MIRROR|g"; \
    fi \
    && echo 'Acquire::Retries "6";' > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl wget \
        unzip zip tar xz-utils \
        jq ripgrep fzf vim less \
        python3 python3-pip python3-venv \
        build-essential \
        sqlite3 \
        procps net-tools iputils-ping dnsutils \
    && rm -rf /var/lib/apt/lists/* \
# libaio (Oracle 运行时依赖): Debian 13+ 改名 libaio1t64, 旧版 Debian/Ubuntu 仍叫 libaio1
    && (apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libaio1t64 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libaio1) \
    && rm -rf /var/lib/apt/lists/*

# ---------- 2. yq (apt 源里没有, GitHub 最新版; GitHub 资产下载不稳, 带 curl 重试) ----------
RUN YQ_ARCH=$([ "$TARGETARCH" = arm64 ] && echo arm64 || echo amd64) \
    && curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}" \
        -o /usr/local/bin/yq \
    && chmod 755 /usr/local/bin/yq

# ---------- 3. Node v24 LTS (留空自动取最新 24.x; npmmirror 二进制镜像) ----------
RUN if [ -z "$NODE_VERSION" ]; then \
        NODE_VERSION=$(curl -fsSL 'https://nodejs.org/dist/index.json' \
            | grep -oP '"version":\s*"\Kv24\.[0-9.]+' | head -1); \
    fi \
    && echo "Installing Node ${NODE_VERSION}" \
    && NODE_ARCH=$([ "$TARGETARCH" = arm64 ] && echo arm64 || echo x64) \
    && curl -fsSL "https://registry.npmmirror.com/-/binary/node/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        | tar -xJ --strip-components=1 -C /usr/local

# ---------- 4. Python 3.14 (python-build-standalone 预编译包, 自动取最新 3.14.x) ----------
# 优先 npmmirror 国内镜像 (GitHub 资产下载/DNS 经常不稳); 失败回退 GitHub 官方 API
# 预编译包解压到 /usr/local 后, /usr/local/bin/python3 优先于系统 /usr/bin/python3(3.13)
RUN if [ -z "$PYTHON_URL" ]; then \
        PY_ARCH=$([ "$TARGETARCH" = arm64 ] && echo aarch64 || echo x86_64); \
        PBS_DIR=$(curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
            "https://registry.npmmirror.com/-/binary/python-build-standalone/" 2>/dev/null \
            | jq -r '[.[]|select(.type=="dir")|.name]|last' || true) \
        && PYTHON_NAME=$(curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
            "https://registry.npmmirror.com/-/binary/python-build-standalone/${PBS_DIR}/" 2>/dev/null \
            | jq -r --arg a "$PY_ARCH" \
                '[.[]|.name|select(test("^cpython-3\\.14\\.[0-9.]+\\+"+$a+"-unknown-linux-gnu-install_only\\.tar\\.gz$"))]|first' || true) \
        && PYTHON_URL="https://registry.npmmirror.com/-/binary/python-build-standalone/${PBS_DIR}/${PYTHON_NAME}" \
        && case "$PYTHON_NAME" in cpython-*) ;; *) PYTHON_URL=""; esac; \
    fi \
    && if [ -z "$PYTHON_URL" ]; then \
        echo "npmmirror 未命中, 回退 GitHub API ..." \
        && PY_ARCH=$([ "$TARGETARCH" = arm64 ] && echo aarch64 || echo x86_64) \
        && PYTHON_URL=$(curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
            https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
            | grep -oP '"browser_download_url":\s*"\K[^"]*cpython-3\.14\.[0-9.]+[^"]*'${PY_ARCH}'-unknown-linux-gnu-install_only\.tar\.gz' \
            | grep -v freethreaded | head -1 || true); \
    fi \
    && if [ -z "$PYTHON_URL" ]; then \
        echo "ERROR: 无法获取 Python 3.14 下载地址 (镜像源与 GitHub 均不可达), 请 --build-arg PYTHON_URL=<完整直链> 后重试" >&2; exit 1; \
    fi \
    && echo "Installing Python: ${PYTHON_URL}" \
    && curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors "$PYTHON_URL" -o /tmp/py.tgz \
    && tar -xzf /tmp/py.tgz --strip-components=1 -C /usr/local \
    && rm -f /tmp/py.tgz \
    && python3 -m ensurepip --upgrade \
    && python3 --version && pip3 --version | cut -d' ' -f1-2

# ---------- 5. Go (go.dev 自动取最新版, 失败回退阿里云镜像) ----------
RUN GO_VER=$(if [ -n "$GO_VERSION" ]; then echo "$GO_VERSION"; \
        else curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
            'https://go.dev/dl/?mode=json' \
            | grep -oP '"version":\s*"\Kgo[0-9.]+' | head -1 | sed 's/^go//'; fi) \
    && echo "Installing Go ${GO_VER}" \
    && GO_ARCH=$([ "$TARGETARCH" = arm64 ] && echo arm64 || echo amd64) \
    && (curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
            "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz \
        || curl -fsSL --retry 6 --retry-delay 3 --retry-all-errors \
            "https://mirrors.aliyun.com/golang/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz) \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz

# ---------- 6. opencode (本地二进制, root 安装到系统路径) ----------
# 官方镜像的 coder 用户自带免密 sudo, 但我们把 opencode 装到 /usr/local/bin,
# coder 直接可用; opencode 运行时写入 ~/ 的内容由 coder 自己创建, 无权限问题
# 文件名与 buildx 注入的 TARGETARCH 值一致 (amd64/arm64), 单条 COPY 只带进
# 目标架构的二进制, 避免两个 184MB 都留在镜像层 (曾导致镜像白多 184MB)。
# NOTE: 依赖 BuildKit 自动注入 TARGETARCH (Docker Desktop 默认开启;
#       如用 DOCKER_BUILDKIT=0 的传统构建器会因变量为空而报 COPY 找不到源文件)
COPY opencode-bin-cli/opencode-linux-${TARGETARCH} /usr/local/bin/opencode
RUN chmod 755 /usr/local/bin/opencode

# ---------- 7. Oracle Instant Client (构建时自动下载) ----------
# 提供 libclntsh.so (oracleclient) 等 OCI 库, 供 python-oracledb(thick 模式)/cx_Oracle 等使用
# x64: 官方 latest 别名链接; arm64: 固定版本直链 (见 ORACLE_ARM64_URL 构建参数)
RUN if [ "$TARGETARCH" = arm64 ]; then \
        OIC_URL="$ORACLE_ARM64_URL"; \
    else \
        OIC_URL="https://download.oracle.com/otn_software/linux/instantclient/instantclient-basic-linux.zip"; \
    fi \
    && mkdir -p /opt/oracle \
    && echo "Downloading Oracle Instant Client: ${OIC_URL}" \
    && curl -fsSL "$OIC_URL" -o /tmp/oic.zip \
    && unzip -q /tmp/oic.zip -d /opt/oracle \
    && rm -f /tmp/oic.zip \
    && mv /opt/oracle/instantclient_* /opt/oracle/instantclient \
    && echo "/opt/oracle/instantclient" > /etc/ld.so.conf.d/oracle-instantclient.conf \
    && ldconfig

# ---------- 8. 国内镜像源配置 ----------
# npm: registry + 全局安装前缀放全局配置 (注意: prefix 不能写在 ~/.npmrc,
#      coder 的 HOME 即工作区根目录, npm 会把它当项目级配置而报错)
RUN printf "registry=https://registry.npmmirror.com\nprefix=/home/coder/.local\n" > /usr/local/etc/npmrc
# npm: coder 用户级只配 registry
RUN printf "registry=https://registry.npmmirror.com\n" > /home/coder/.npmrc \
    && chown coder:coder /home/coder/.npmrc \
    && mkdir -p /home/coder/.local/bin \
    && chown -R coder:coder /home/coder/.local
# pip: 清华镜像
RUN printf "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ntrusted-host = pypi.tuna.tsinghua.edu.cn\n" > /etc/pip.conf

# ---------- 9. 环境变量 ----------
ENV TZ=Asia/Shanghai
ENV PATH=/usr/local/go/bin:/home/coder/.local/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/oracle/instantclient
# Go 模块代理 (国内加速)
ENV GOPROXY=https://goproxy.cn,direct

# 登录 shell 修复: /etc/profile 会无条件重置 PATH, 冲掉上面的 ENV PATH,
# 导致 code-server 登录终端里 go / ~/.local/bin 下的命令 "Unknown command"
RUN printf 'export PATH=/usr/local/go/bin:/home/coder/.local/bin:$PATH\n' \
        > /etc/profile.d/dev-path.sh \
    && chmod 644 /etc/profile.d/dev-path.sh

# ---------- 10. 预置目录 (opencode skills 全局目录等, compose 里做持久化) ----------
RUN mkdir -p \
        /home/coder/project \
        /home/coder/.config/.opencode/skills \
        /home/coder/.local/share/opencode \
        /home/coder/.cache/opencode \
        /home/coder/go \
    && chown -R coder:coder /home/coder

# ---------- 11. 运行身份 ----------
# 沿用官方设计: 以 coder(uid 1000) 运行, 官方 ENTRYPOINT 自带
# --bind-addr 0.0.0.0:8080 参数, 且 fixuid 会在启动时把挂载目录
# 属主修正为 coder (解决 Linux 宿主机 root 建目录 coder 无写权限的坑)
USER coder
WORKDIR /home/coder
