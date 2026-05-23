# OpenClaw Offline Builder

为 ARM64 Ubuntu 20.04 离线环境构建 OpenClaw 一键安装包。

## 原理

在 Docker 容器 (`ubuntu:20.04` ARM64) 内通过 `npm install -g openclaw@latest` 安装，
所有原生模块自动为 Linux ARM64 + glibc 2.31 编译，确保与目标机兼容。
最终将 Node.js 运行时 + openclaw 安装产物 + 系统依赖 deb 包一起打包。

## 本地构建

```bash
# 需要 Docker
bash build.sh

# 自定义参数
OPENCLAW_VERSION=2026.5.7 bash build.sh
PLATFORM=linux/amd64 bash build.sh
```

输出: `openclaw-offline-arm64.tar.gz`

## 手动构建（GitHub Actions）

如有需要，请先 fork 本仓库，在你的 fork 中进入 Actions 手动运行
`Build OpenClaw Offline Package` 工作流（可选填写 OpenClaw 版本）。

## 目标机使用

```bash
# 传输到目标机后
tar xzf openclaw-offline-arm64.tar.gz
cd openclaw-offline-arm64
sudo bash install.sh           # 安装 (无需联网)
openclaw setup
bash start-openclaw.sh         # 启动
```

## 包内容

| 文件 | 说明 |
|------|------|
| `payload/node` | Node.js v24 ARM64 运行时 |
| `payload/node_modules_openclaw/` | openclaw 完整安装 |
| `payload/debs/` | 系统依赖 deb 包 |
| `install.sh` | 自动安装脚本 |
| `openclaw.json` | 配置模板 |
| `start-openclaw.sh` | 启动脚本 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PLATFORM` | `linux/arm64` | 目标平台 |
| `BASE_IMAGE` | `ubuntu:20.04` | 基础镜像 |
| `NODE_MAJOR` | `24` | Node.js 主版本 |
| `OPENCLAW_VERSION` | `latest` | OpenClaw 版本 |
| `OUTPUT_DIR` | `$(pwd)` | 输出目录 |
