# ============================================================
# code-server AI 开发环境镜像 (multi-arch: linux/amd64 | linux/arm64)
# Base: codercom/code-server (官方发布镜像, Ubuntu)
# Source repo: https://github.com/coder/code-server
#
# 架构由 --platform 控制 (buildx 自动注入 TARGETARCH):
#   x86_64: docker build --platform linux/amd64 (默认)
#   arm64 : docker build --platform linux/arm64
# Node/Python/Go/yq/opencode/Oracle 下载资源均按 TARGETARCH 自动切换
# ============================================================
FROM codercom/code-server:latest

USER root

# 目标架构: buildx 按 --platform 自动注入 (不指定 = 宿主架构)。
# 注意: 不能写默认值! 写了默认值 (如 =amd64) 会覆盖自动注入的值,
# 导致跨架构构建 arm64 时所有下载仍用 x86_64 资源 (即此前 arm64 构建失败的原因)。
# CI action 里为保险起见还会显式传 --build-arg TARGETARCH=amd64|arm64
ARG TARGETARCH

# ---------- 构建参数 ----------
# apt 镜像源 (留空 = 官方源 deb.debian.org; 网络不通时再改如 mirrors.aliyun.com)
ARG APT_MIRROR=
# Node 版本: 留空 = 构建时自动获取 v24 LTS 最新版 (如需固定: 24.13.1)
ARG NODE_VERSION=
# Python 3.13 预编译包完整下载地址: 留空 = 从 GitHub 自动获取最新 3.13.x
# (python-build-standalone 项目, 离线构建可先下载后用 ARG 指定本地路径不可行,
#  应把 URL 指向内网 HTTP 服务)
ARG PYTHON_URL=
# Go 版本: 留空 = 构建时自动获取最新稳定版
ARG GO_VERSION=

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

# ---------- 2. yq (apt 源里没有, GitHub 最新版) ----------
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" \
        -o /usr/local/bin/yq \
    && chmod 755 /usr/local/bin/yq

# ---------- 3. Node v24 LTS (留空自动取最新 24.x; npmmirror 二进制镜像) ----------
RUN if [ -z "$NODE_VERSION" ]; then \
        NODE_VERSION=$(curl -fsSL 'https://nodejs.org/dist/index.json' \
            | grep -oP '"version":\s*"\Kv24\.[0-9.]+' | head -1); \
    fi \
    && case "$TARGETARCH" in arm64) NODE_ARCH=arm64 ;; *) NODE_ARCH=x64 ;; esac \
    && echo "Installing Node ${NODE_VERSION} (linux-${NODE_ARCH})" \
    && curl -fsSL "https://registry.npmmirror.com/-/binary/node/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        | tar -xJ --strip-components=1 -C /usr/local

# ---------- 4. Python 3.13 (python-build-standalone 预编译包, 自动取最新 3.13.x) ----------
# 预编译包解压到 /usr/local 后, /usr/local/bin/python3 优先于系统 /usr/bin/python3。
# install_only 包已自带 pip (site-packages/pip-*.dist-info + bin/pip3, 指向同目录 python3.13),
# 无需 ensurepip —— 且 arm64 走 QEMU 模拟时 ensurepip 的子进程执行又慢又易出问题, 直接验证版本即可
RUN case "$TARGETARCH" in arm64) PY_ARCH=aarch64 ;; *) PY_ARCH=x86_64 ;; esac \
    && if [ -z "$PYTHON_URL" ]; then \
        PYTHON_URL=$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
            | grep -oP '"browser_download_url":\s*"\K[^"]*cpython-3\.13\.[0-9.]+[^"]*'${PY_ARCH}'-unknown-linux-gnu-install_only\.tar\.gz' \
            | grep -v freethreaded | head -1); \
    fi \
    && echo "Installing Python: ${PYTHON_URL}" \
    && curl -fsSL "$PYTHON_URL" -o /tmp/py.tgz \
    && tar -xzf /tmp/py.tgz --strip-components=1 -C /usr/local \
    && rm -f /tmp/py.tgz \
    && python3 --version && pip3 --version | cut -d' ' -f1-2

# ---------- 5. Go (go.dev 自动取最新版, 失败回退阿里云镜像) ----------
RUN GO_VER=$(if [ -n "$GO_VERSION" ]; then echo "$GO_VERSION"; \
        else curl -fsSL 'https://go.dev/dl/?mode=json' \
            | grep -oP '"version":\s*"\Kgo[0-9.]+' | head -1 | sed 's/^go//'; fi) \
    && echo "Installing Go ${GO_VER}" \
    && (curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz \
        || curl -fsSL "https://mirrors.aliyun.com/golang/go${GO_VER}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz) \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz

# ---------- 6. opencode (本地二进制, root 安装到系统路径) ----------
# 官方镜像的 coder 用户自带免密 sudo, 但我们把 opencode 装到 /usr/local/bin,
# coder 直接可用; opencode 运行时写入 ~/ 的内容由 coder 自己创建, 无权限问题
# 二进制按目标架构命名: opencode-linux-x64 / opencode-linux-arm64,
# 构建上下文 opencode-bin-cli/ 里只放目标架构那一个 (CI/action 会按架构自动下载)
COPY opencode-bin-cli/opencode-* /usr/local/bin/opencode
RUN chmod 755 /usr/local/bin/opencode

# ---------- 7. Oracle Instant Client (构建时自动下载最新版) ----------
# 提供 libclntsh.so (oracleclient) 等 OCI 库, 供 python-oracledb(thick 模式)/cx_Oracle 等使用
RUN case "$TARGETARCH" in \
        arm64) OIC_URL="https://download.oracle.com/otn_software/linux/instantclient/instantclient-basic-linux-arm64.zip" ;; \
        *)     OIC_URL="https://download.oracle.com/otn_software/linux/instantclient/instantclient-basic-linux.zip" ;; \
    esac \
    && mkdir -p /opt/oracle \
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
