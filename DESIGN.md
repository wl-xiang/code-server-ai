# code-server AI 开发环境 — 设计与流程文档

> 本文档记录镜像与编排的完整设计思路、需求映射、踩坑修复和构建/打包/部署流程。
> 上手一个新服务器或修改镜像前，请先读完本文。

## 1. 项目背景

- **办公 PC**：Windows 7 老机器，无法安装新版 AI/Coding 工具 → 一切工具必须以 **Web 服务** 形式部署在服务器上，老 PC 只用浏览器访问
- **服务器**：CentOS 7（内核 3.10，glibc 老），有 **x86_64 和 ARM64** 两种架构，不能在宿主机直接装新软件
- **核心思路**：Docker 容器自带完整用户态，宿主机只需内核 3.10+ 和可用的 Docker；把 code-server（浏览器版 VS Code）+ opencode（AI CLI）+ 多语言运行时全部打包进**一个镜像**，离线 tar 或 registry 分发

## 2. 需求 → 实现映射

| 原始需求（prompt.txt） | 实现方式 | 位置 |
|---|---|---|
| code-server 基础镜像 | `FROM codercom/code-server:latest`（官方发布镜像，自带 4.135.0） | Dockerfile 顶部 |
| VSIX 插件持久化 | bind mount `~/.local/share/code-server` + `~/.config/code-server` | compose `volumes` |
| opencode 二进制 | 本地二进制 COPY 进镜像 `/usr/local/bin/`（root 构建、coder 可用） | Dockerfile §6 |
| opencode 权限坑（root 才能安装到 ~/） | 官方镜像 coder(uid 1000) 自带免密 sudo；系统级安装到 /usr/local；用户级安装走 `~/.local`（npm prefix 指向此处，免 sudo） | Dockerfile §6/§8 |
| opencode 配置/skills/node_modules 持久化 | `~/.config/.opencode`、`~/.local/share/opencode`、`~/.cache/opencode` 分别独立挂载 | compose `volumes` |
| npm 镜像源/固定依赖一键安装 | registry 指向 npmmirror；缓存目录挂载 `~/.npm`，离线 `npm install --offline` | Dockerfile §8 |
| python + pip | Python 3.14（python-build-standalone 预编译）+ pip 清华源 | Dockerfile §4 |
| node + npm | Node v24 LTS（npmmirror 二进制自动取最新 24.x） | Dockerfile §3 |
| go + go 包 | Go 最新稳定版（go.dev JSON 自动取）+ GOPROXY=goproxy.cn | Dockerfile §5 |
| 常用工具 jq/rg/yq | apt 装 jq/ripgrep/fzf，yq 单独从 GitHub 下最新版 | Dockerfile §1/§2 |
| AI CLI / local MCP CLI | **不预装**（保持镜像纯净），npm prefix 已指向 `~/.local`，容器内 `npm i -g <cli>` 免 sudo 且落在挂载目录持久化 | compose `./volumes/local-bin` |
| oracleclient.so | Oracle Instant Client Basic 构建时自动下载，`ldconfig` 注册 | Dockerfile §7 |
| 全局 skills 目录持久化 | `~/.config/.opencode/skills` 随 `./volumes/opencode-config` 挂载 | compose `volumes` |
| 一键 up/down | docker compose 编排 + healthcheck | docker-compose.yaml |
| 离线分发 | `docker save \| gzip` 出带架构标识的 tgz + sha256 | build.sh / 打包流程 §7 |

## 3. 镜像分层设计（Dockerfile 段落结构）

```
codercom/code-server:latest        ← 官方镜像（Debian 13, code-server 4.135.0）
 ├ §1 apt 系统依赖                 jq/rg/fzf/vim/python3/build-essential/libaio 等
 ├ §2 yq                          GitHub 最新版（apt 源里没有）
 ├ §3 Node v24 LTS                npmmirror 二进制 tarball → /usr/local
 ├ §4 Python 3.14                 python-build-standalone 预编译 → /usr/local
 ├ §5 Go 最新稳定版               go.dev 官方 tarball → /usr/local/go
 ├ §6 opencode                    本地二进制 COPY → /usr/local/bin
 ├ §7 Oracle Instant Client       构建时下载 → /opt/oracle + ldconfig
 ├ §8 国内镜像源配置              npm(npmmirror) / pip(清华) / GOPROXY(goproxy.cn)
 ├ §9 环境变量 + 登录 shell PATH 修复（/etc/profile.d/dev-path.sh）
 ├ §10 预置目录                   project / opencode skills / go 等, chown coder
 └ §11 运行身份                   USER coder + 官方 ENTRYPOINT 原样保留
```

**设计原则**：镜像只含**运行时**，不含任何项目依赖（已实测：pip 仅
pip/setuptools、npm -g 仅 npm 自身、Go 模块缓存为空）。所有第三方依赖由
用户按 §6 的离线方案自行安装，装出来的内容全部落在挂载目录，重建容器不丢。

## 4. 关键踩坑与决策记录（重要！改镜像前必读）

### 4.1 基础镜像已是 Debian 13 (trixie)，不是 Ubuntu
- `libaio1` 在 trixie 改名 `libaio1t64` → Dockerfile 用 `install libaio1t64 || libaio1` 兼容两种
- apt 源是 `deb.debian.org`，换源 sed 要覆盖它

### 4.2 apt 镜像源不可靠
- 阿里云源出现 404/连接失败，官方源反而快 → **默认用官方源**（`ARG APT_MIRROR` 留空），
  并写入 `Acquire::Retries "6"` 抗网络抖动。网络真不通时再显式换源

### 4.3 npm prefix 绝不能写 `~/.npmrc`
- coder 的 HOME 就是工作区根目录，npm 会把 `~/.npmrc` 当**项目级配置**，
  prefix 出现在项目配置里直接报错 `config prefix cannot be changed`
- 正确做法：prefix + registry 写进 `/usr/local/etc/npmrc`（npm 全局配置），
  用户级 `~/.npmrc` 只留 registry

### 4.4 永远不要覆盖官方 ENTRYPOINT
- 官方镜像 `USER=1000` 直接运行，且 `--bind-addr 0.0.0.0:8080` 是官方
  ENTRYPOINT 参数的一部分。自定义 ENTRYPOINT 会**丢失默认参数**，导致
  以 root 身份运行且只监听 127.0.0.1（服务外面连不上）
- 正确做法：保留官方入口；Linux 宿主机上 compose 自动创建的 root 属主目录
  由官方 `fixuid`（setuid 二进制）在启动时自动 chown 给 coder，无需手写脚本

### 4.5 登录 shell 的 PATH 会被 /etc/profile 重置
- 现象：`docker exec sh -c 'go version'` 正常，但 code-server 网页终端里
  `go` 提示 Unknown command
- 根因：`/etc/profile` 无条件覆盖 PATH，冲掉 Dockerfile `ENV PATH` 里的
  `/usr/local/go/bin` 和 `~/.local/bin`
- 修复：镜像内写入 `/etc/profile.d/dev-path.sh`（export 两个路径），
  登录/非登录 shell 全覆盖

### 4.6 code-server 自带会话记忆，不要动 WORKDIR
- 曾把 WORKDIR 改成 project 目录想让登录后默认打开项目区，实测发现
  code-server 本来就会打开**上次会话的目录**，该修改已撤回。WORKDIR 保持 `/home/coder`

### 4.7 预编译运行时的选择
- **Python**：Debian 仓库只有 3.13，用 astral 的 python-build-standalone
  预编译包（解压到 /usr/local，`/usr/local/bin/python3` 优先于系统 3.13，
  自带 pip，venv 可用）。注意 release 里还有 free-threaded 变体，grep 时要排除
- **Node**：npmmirror 同步全部官方版本，直接下 tarball（不用 NodeSource apt）
- **Go**：`https://go.dev/dl/?mode=json` 构建时取最新稳定版，失败回退阿里云镜像
- 三个运行时都可用 build-arg 固定版本（`NODE_VERSION` / `PYTHON_URL` / `GO_VERSION`）

### 4.8 shell 语法细节
- 子 shell 不能收参数：`(curl A || curl B) -o file` 是语法错误，
  `-o` 必须写进每个 curl

### 4.9 构建机环境差异
- Windows Docker Desktop 构建：build context 内文件全部变 755，属官方安全提示可忽略
- 本机 docker CLI 缺 compose/buildx 插件时：`docker compose images` 不可用，
  打包脚本 3-A 需手动等效执行（见 §7）

## 5. 持久化设计（compose）

所有挂载统一放在宿主机 `./volumes/` 下（compose 与代码同目录部署）：

| 宿主机（./volumes/…） | 容器路径 | 内容 |
|---|---|---|
| `workspace` | `/home/coder/project` | 项目代码（含各项目的 venv/node_modules/vendor） |
| `code-server-data` | `~/.local/share/code-server` | VSIX 扩展、用户数据 |
| `code-server-config` | `~/.config/code-server` | code-server 配置 |
| `opencode-config` | `~/.config/.opencode` | opencode 全局配置 + **全局 skills** |
| `opencode-share` | `~/.local/share/opencode` | opencode 状态/会话 |
| `opencode-cache` | `~/.cache/opencode` | opencode 缓存 |
| `local-bin` | `~/.local` | npm 全局安装点（AI CLI / MCP CLI） |
| `npm-cache` | `~/.npm` | npm 下载缓存（离线安装用） |
| `pip-cache` | `~/.cache/pip` | pip 下载缓存 |
| `python-wheels` | `~/wheels` | 离线 wheel 投放目录 |
| `go-workspace` | `~/go` | GOPATH（pkg/mod 模块缓存） |

要点：
- `~/.config/.opencode` **单独挂载**，不能整体挂 `~/.config`（会互相吞掉）
- 全部 bind mount，`docker compose down` / 容器重建 / 换镜像均不丢数据
- 首次 `up` 自动建目录，属主由 fixuid 自动修正，**禁止手动 chown 脚本**

## 6. 离线装依赖（在线收集 → 传入挂载目录 → 容器内离线安装）

**原则：镜像不动，依赖随数据走。**

### Python (pip)
```bash
# 在线机（同一镜像容器内收集, 保证 .whl 与容器 glibc 匹配）
docker run --rm -v ./volumes/python-wheels:/home/coder/wheels -w /home/coder/wheels \
    code-server-ai:latest pip download -r requirements.txt -d /home/coder/wheels
# → ./volumes/python-wheels 整目录拷到服务器
# 容器内装进项目 venv（venv 在 ./volumes/workspace 下, 天然持久化）
python3 -m venv /home/coder/project/myapp/.venv
/home/coder/project/myapp/.venv/bin/pip install --no-index \
    --find-links=/home/coder/wheels -r requirements.txt
```

### Node (npm)
- 方案 A（推荐）：在线机同一容器里 `npm install`，`node_modules` 随项目整体打包
  （同镜像同平台，原生编译二进制完全兼容）
- 方案 B：在线装一次填满 `./volumes/npm-cache` → 拷服务器 → `npm install --offline`
- 全局 CLI：`npm i -g <cli>` 直接落 `./volumes/local-bin`，免 sudo 持久化

### Go
- 方案 A（推荐）：`go mod vendor`，vendor/ 进项目目录随项目打包，构建自动使用
- 方案 B：`go mod download` 后模块缓存就在 `./volumes/go-workspace/pkg/mod`，
  整目录拷贝，离线构建 `GOPROXY=off go build ./...`

## 7. 构建 / 打包 / 发布流程

### 7.1 构建（构建机在线）
```bash
./build.sh                        # = docker build + docker save 出未压缩 tar
# 固定版本示例:
docker build --build-arg NODE_VERSION=24.13.1 --build-arg GO_VERSION=1.27.1 \
    --build-arg APT_MIRROR= -t code-server-ai:latest .
```
- 默认构建 `linux/amd64`；ARM64 时把 Dockerfile 中的 x64 资源名换成 arm64
  （opencode 二进制 / Node tarball / Go tarball / yq 文件名），强烈建议找原生
  ARM 机器构建，QEMU 模拟极慢
- opencode 二进制不在源码包里，重建前放 `opencode-bin-cli/opencode-linux-x64`

### 7.2 打包（repo-deploy-packager Skill 规范）
```
results/<项目名>/<项目名>_docker-images_<os>-<arch>.tgz   ← docker save | gzip
results/<项目名>/<项目名>_source-code_<os>-<arch>.tgz     ← 最小源码包
results/<项目名>/<项目名>_sha256_<os>-<arch>.txt          ← 校验和
logs/<项目名>_save.log / _tar.log / _pack.log              ← 全过程日志
```
- **文件名强制带 `<os>-<arch>` 后缀**（多架构产物同目录不混淆）
- 源码包只含：Dockerfile、docker-compose.yaml、README.md、DESIGN.md（本文）、
  build.sh、.dockerignore —— 保持简洁，大文件（opencode 二进制、中间 tar）一律不入包
- 验收清单：tgz 可 `docker load` 回载且镜像 ID 与构建一致 / 源码可解包、无 .git /
  sha256 已记录

### 7.3 发布（三选一，可并存）
1. **离线 tar**：`results/*.tgz` 直接拷贝到服务器，`docker load -i`（兜底方案）
2. **内网 registry**：挑一台常开服务器跑 `registry:2` 容器，构建机
   `docker tag` 后 push，其他服务器 pull（完全离线内网；HTTP 需配
   insecure-registries，生产建议加 TLS）
3. **云 registry 备份**：腾讯云 TCR / 阿里云 ACR 个人版免费，推一份异地容灾；
   国内公共加速器只支持拉取转发，**不能推送**

### 7.4 服务器部署
```bash
docker load -i code-server-image_docker-images_linux-amd64.tgz
# 把 source-code 包解到部署目录（compose 就在其中）
docker compose up -d          # 停止: docker compose down（数据不丢）
# 浏览器访问 http://<服务器IP>:8080，密码在 compose 的 PASSWORD
```

## 8. 常用验证命令（容器内）

```bash
opencode --version && go version && node -v && python3 --version
jq --version && rg --version && yq --version && fzf --version
ls /opt/oracle/instantclient/libclntsh.so    # Oracle 库
npm config get registry                      # npmmirror
go env GOPROXY                               # goproxy.cn
bash -lc 'go version'                        # 登录 shell PATH 修复生效
```

## 9. 当前版本基线（2026-09-08 验证）

| 组件 | 版本 | 备注 |
|---|---|---|
| code-server | 4.135.0 | 跟随官方 latest |
| opencode | 1.18.29 | 本地二进制烧录 |
| Node.js | v24.20.0 (LTS) | 自动取 24.x 最新，ARG 可固定 |
| Python | 3.14.7 (pip 26.2.1) | 自动取 3.14.x 最新 |
| Go | 1.27.1 | 自动取最新稳定版 |
| Oracle Instant Client | 21c | 构建时自动下载最新 |

ARM64 版本尚未构建；构建方法见 §7.1。

## 10. FAQ

**Q: 宿主机命令行输入 `go` 提示 Unknown command？**
正常。Go 只在容器内（`/usr/local/go/bin/go`）。用 code-server 网页终端或
`docker exec -it code-server-ai bash`。

**Q: 为什么镜像里不预装 agent-browser / open-code-review 等工具？**
保持镜像纯净、避免随依赖膨胀。npm prefix 已指向挂载目录，`npm i -g` 装完
即持久化，重装容器不丢。

**Q: 密码写在哪？**
compose 的 `PASSWORD` 环境变量（明文），生产建议改掉默认值或换 `HASHED_PASSWORD`。
