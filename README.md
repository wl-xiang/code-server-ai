# code-server AI 开发环境镜像 (x86_64 / ARM64)

> **完整设计思路、踩坑修复记录与构建/打包/部署流程见 [DESIGN.md](DESIGN.md)，改镜像前必读。**

基于官方 `codercom/code-server` (Debian 13 / code-server 4.135.0) 的增量定制镜像，
面向老服务器 (CentOS 7 / 内核 3.10+) 的浏览器远程开发场景。

## 镜像内容

| 组件 | 版本 | 说明 |
|---|---|---|
| code-server | 4.135.0 | 官方镜像自带 |
| opencode | 1.18.29 | `/usr/local/bin/opencode`，本地二进制烧录 |
| Node.js | v24.20.0 (LTS) | `/usr/local`，npm registry 已指向 npmmirror |
| Python | 3.14.7 | python-build-standalone 预编译，含 pip 26.2.1 / venv，pip 已指向清华镜像 |
| Go | 1.27.1 | `/usr/local/go`，GOPROXY 已指向 goproxy.cn |
| Oracle Client | 21c | `/opt/oracle/instantclient`，libclntsh.so (oracleclient) 全套 |
| 常用工具 | — | jq / rg (ripgrep) / yq / fzf / vim / sqlite3 / unzip / git |
| 编译链 | — | gcc/g++/make (node-gyp、pip 源码包编译用) |
| 网络调试 | — | ping / nslookup / netstat 等 |

## 本机构建 (x86_64, 原生)

```bash
./build.sh          # 构建并导出 code-server-ai_amd64.tar
```

或手动：

```bash
docker build --platform linux/amd64 -t code-server-ai:latest .
docker save -o code-server-ai_amd64.tar code-server-ai:latest
```

## 跨架构构建 (x86_64 + ARM64)

```bash
./buildx.sh             # 等同于 ./buildx.sh amd64, 只构建 x86_64
./buildx.sh arm64       # 只构建 ARM64 (QEMU 模拟, 30-60 分钟, 勿中断)
./buildx.sh all         # 两个架构都构建, 各导出一个 tgz
```

脚本自动完成：buildx 插件检查 → QEMU binfmt 预检与安装 → 选择 desktop-linux
构建器 → 按架构构建并自检（`uname -m` / opencode / node / python / go）→
`docker save | gzip` 导出 `results/code-server-image/code-server-image_docker-images_linux-<arch>.tgz`。

- **arm64 包的镜像 tag 是 `code-server-ai:arm64`**，ARM 服务器上 load 后先
  `docker tag code-server-ai:arm64 code-server-ai:latest` 再 compose up
- 可选参数通过环境变量透传：`NODE_VERSION= GO_VERSION= APT_MIRROR= BASE_IMAGE=`
- Docker Hub 不通时切镜像代理：`BASE_IMAGE=dockerproxy.net/codercom/code-server:latest ./buildx.sh arm64`

构建参数（可选覆盖）：

```bash
docker build --build-arg NODE_VERSION=22.14.0 --build-arg GO_VERSION=1.27.1 \
    --build-arg APT_MIRROR=mirrors.aliyun.com -t code-server-ai:latest .
```

## 服务器部署 (CentOS 7)

```bash
# 1. 导入镜像
docker load -i code-server-ai_amd64.tar

# 2. 上传 docker-compose.yaml，与镜像同一目录，启动
docker compose up -d

# 3. 停止 (数据在挂载目录，不会丢)
docker compose down
```

浏览器访问 `http://<服务器IP>:8080`，密码在 compose 的 `PASSWORD` 环境变量中。
code-server 自带会话记忆：再次登录时会打开上一次浏览的目录。

> ARM64 版本直接 `./buildx.sh arm64`（本机 QEMU 模拟构建），或在 ARM 机器上原生构建（更快）。
> 双架构构建的详细说明见上文「跨架构构建」章节。

## 持久化目录一览

| 宿主机目录 | 容器路径 | 用途 |
|---|---|---|
| `./volumes/workspace` | `/home/coder/project` | 项目代码 |
| `./volumes/code-server-data` | `~/.local/share/code-server` | VSIX 扩展、用户数据 |
| `./volumes/code-server-config` | `~/.config/code-server` | code-server 配置 |
| `./volumes/opencode-config` | `~/.config/.opencode` | opencode 全局配置 + **skills** |
| `./volumes/opencode-share` | `~/.local/share/opencode` | opencode 状态/会话数据 |
| `./volumes/opencode-cache` | `~/.cache/opencode` | opencode 缓存 |
| `./volumes/local-bin` | `~/.local` | **AI CLI / MCP CLI 安装点**（npm 全局前缀） |
| `./volumes/npm-cache` | `~/.npm` | npm 下载缓存（离线装依赖用） |
| `./volumes/pip-cache` | `~/.cache/pip` | pip 下载缓存（离线装依赖用） |
| `./volumes/python-wheels` | `~/wheels` | 离线 wheel 投放目录 |
| `./volumes/go-workspace` | `~/go` | GOPATH（含 pkg/mod 模块缓存，离线可用） |

> 目录属主问题已由官方镜像的 `fixuid` 在容器启动时自动修正，无需手动 chown。

## AI CLI / MCP CLI 安装方式（免 sudo，且持久化）

npm 全局前缀已指向 `~/.local`（对应宿主机 `./volumes/local-bin`），容器内直接：

```bash
npm i -g <某个-ai-cli>
npm i -g <某个-mcp-cli>
```

二进制落在 `~/.local/bin`（已在 PATH），宿主机 `./volumes/local-bin/` 可见、重建容器不丢。
opencode 全局 skills 放宿主机 `./volumes/opencode-config/skills/` 即可，容器内路径
`~/.config/.opencode/skills/`。

## 离线环境装依赖（三种运行时）

原则：**运行时本身已烧进镜像**（tar 就是离线载体），需要处理的是项目依赖。
流程统一为"在线机上收集 → 拷进服务器挂载目录 → 容器内离线安装"。

### Python（pip）

```bash
# ① 在线机收集依赖 (在有网的容器里执行, 产物是纯 .whl 文件, 与运行环境同容器保证兼容)
docker run --rm -v ./volumes/python-wheels:/home/coder/wheels -w /home/coder/wheels \
    code-server-ai:latest \
    pip download -r requirements.txt -d /home/coder/wheels

# ② 把 ./volumes/python-wheels 目录拷到服务器 (目录已挂载到容器 /home/coder/wheels)

# ③ 容器内离线安装 (建议装进项目 venv, venv 位于 ./volumes/workspace → 天然持久化)
python3 -m venv /home/coder/project/myapp/.venv
/home/coder/project/myapp/.venv/bin/pip install \
    --no-index --find-links=/home/coder/wheels -r requirements.txt
```

- venv 建在项目目录里 → 随 `./volumes/workspace` 持久化，重建容器不丢
- `./volumes/pip-cache` 已挂载：在线装过一次的包，缓存自动留存，下次 `pip install` 秒装

### Node（npm）

```bash
# 方案 A (推荐): vendor 思路 —— 在线机在容器里装好, node_modules 随项目整体拷贝
#   同一镜像同一平台, 原生编译的 .node 二进制完全兼容
docker run --rm -v ./volumes/workspace:/home/coder/project code-server-ai:latest \
    sh -c 'cd /home/coder/project/myapp && npm install'

# 方案 B: 缓存复用 —— 在线机装一次后, ./volumes/npm-cache 已填满, 打包传服务器
#   容器内用缓存离线安装:
npm install --offline

# 全局 CLI 工具 (agent-browser 等): npm i -g → 落在 ./volumes/local-bin, 天然持久化
npm i -g <cli>
```

### Go

```bash
# 方案 A (推荐): vendor —— 模块源码进项目目录, 随项目打包, go 命令自动优先使用
cd /home/coder/project/myapp
go mod vendor          # 在线执行一次; 之后 go build ./... 自动走 vendor/, 离线可用

# 方案 B: 模块缓存 —— GOPATH 挂载在 ./volumes/go-workspace, 在线 go mod download 后
#   模块缓存就在宿主机 ./volumes/go-workspace/pkg/mod 里, 整目录拷到服务器即可
go mod download
GOPROXY=off go build ./...   # 离线构建 (强制只用本地缓存)
```

### 持久化说明

以上目录全部是宿主机 bind mount，`docker compose down` / 容器重建 / 换镜像
都不会丢内容；第一次 `docker compose up -d` 会自动创建缺失目录，属主问题由
官方 `fixuid` 在启动时自动修正，无需手动 chown。

## opencode 热升级

镜像内已烧录 opencode。升级时把新二进制放到宿主机 `./opencode-bin-cli/opencode-linux-amd64`，
取消 `docker-compose.yaml` 里这行注释后 `docker compose up -d`：

```yaml
- ./opencode-bin-cli/opencode-linux-amd64:/usr/local/bin/opencode:ro
```

## 常用验证命令（容器内）

```bash
opencode --version && go version && node -v && python3 --version
jq --version && rg --version && yq --version && fzf --version
ls /opt/oracle/instantclient/libclntsh.so   # Oracle 库
npm config get registry                     # 应为 npmmirror
go env GOPROXY                              # 应为 goproxy.cn
```

## FAQ

**Q: 命令行输入 `go` 提示 Unknown command？**

Go 只存在于**容器内部**：`/usr/local/go/bin/go`，宿主机（CentOS 7）上没有。
进入容器环境再用：code-server 网页终端、`docker exec -it code-server-ai bash`、
或 `docker compose exec code-server bash`。容器里登录/非登录 shell 的 PATH
均已包含 `/usr/local/go/bin` 和 `/home/coder/.local/bin`（由镜像内
`/etc/profile.d/dev-path.sh` 保证，/etc/profile 重置 PATH 也不会丢）。

**Q: 镜像里预装了哪些第三方依赖？**

没有。镜像只包含运行时本身（Node / Python / Go 解释器与工具链、code-server、
opencode、Oracle Client、jq/rg/yq/fzf 等系统工具），已实测确认：
pip 仅 pip/setuptools，npm -g 仅 npm 自身，Go 模块缓存为空。
所有项目依赖均按「离线环境装依赖」章节由用户自行安装、按需持久化。


## 注意事项

- CentOS 7 宿主机只需内核 3.10+ 和可用的 Docker，容器用户态自带，不受宿主 glibc 限制
- 端口 `8080:8080` 暴露在局域网；如仅本机使用改回 `127.0.0.1:8080:8080`
- 密码是明文写在 compose 里的，建议改掉默认值，或后续换 `HASHED_PASSWORD`
- 镜像约 3.34GB，tar 包约 3.2GB，拷贝到服务器预留足够空间
