#!/usr/bin/env bash
#
# build.sh — 构建 OpenClaw ARM64 Ubuntu 20.04 离线安装包
#
# 用法:
#   bash build.sh                    # 默认构建 arm64
#   bash build.sh --platform arm64   # 显式指定架构
#   bash build.sh --help             # 查看帮助
#
set -euo pipefail

# ─── 配置 ────────────────────────────────────────────────────
PLATFORM="${PLATFORM:-linux/arm64}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:20.04}"
NODE_MAJOR="${NODE_MAJOR:-24}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
CONTAINER_NAME="openclaw-build-$$"
PACKAGE_NAME="openclaw-offline-arm64"

# ─── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── 帮助 ────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
用法: bash build.sh [选项]

环境变量:
  PLATFORM          目标平台 (默认: linux/arm64)
  BASE_IMAGE        基础镜像 (默认: ubuntu:20.04)
  NODE_MAJOR        Node.js 主版本 (默认: 24)
  OPENCLAW_VERSION  OpenClaw 版本 (默认: latest)
  OUTPUT_DIR        输出目录 (默认: 当前目录)

示例:
  bash build.sh
  PLATFORM=linux/amd64 bash build.sh
  OPENCLAW_VERSION=2026.5.7 bash build.sh
EOF
  exit 0
fi

# ─── 前置检查 ────────────────────────────────────────────────
for cmd in docker tar; do
  command -v "$cmd" >/dev/null 2>&1 || { error "缺少依赖: $cmd"; exit 1; }
done

# ─── 构建脚本 (在容器内执行) ─────────────────────────────────
BUILD_SCRIPT=$(cat <<'INNER_SCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# 重试函数: retry <次数> <命令...>
retry() {
  local n=$1; shift
  for i in $(seq 1 "$n"); do
    if "$@"; then return 0; fi
    echo "  第 $i/$n 次失败，${i}s 后重试..."
    sleep "$i"
  done
  echo "  已重试 $n 次，仍然失败" >&2
  return 1
}

echo "============================================"
echo "  OpenClaw 离线构建"
echo "  Platform: $(uname -m) / $(cat /etc/os-release | grep VERSION_CODENAME | cut -d= -f2)"
echo "============================================"

# Step 1: 基础工具 + 保留 apt 缓存
echo ""
echo "[1/5] 安装基础工具..."
# 禁用自动清理 deb 缓存 (Docker 镜像默认会清理)
rm -f /etc/apt/apt.conf.d/docker-clean 2>/dev/null || true
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/99keep-debs
retry 5 apt-get update -qq
retry 5 apt-get install -y -qq curl xz-utils ca-certificates

# Step 2: Node.js
echo ""
echo "[2/5] 安装 Node.js..."
NODE_VER=$(retry 3 curl -sL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" \
  | grep 'linux-arm64.tar.xz' | head -1 \
  | sed 's/.*node-v\([0-9.]*\)-linux.*/\1/')
echo "  版本: v${NODE_VER}"
retry 3 curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-arm64.tar.xz" \
  | tar xJ -C /usr/local --strip-components=1
echo "  Node.js $(node -v), npm $(npm -v)"

# Step 3: 编译工具 + 运行时依赖
echo ""
echo "[3/5] 安装编译工具和运行时依赖..."
retry 5 apt-get install -y -qq build-essential python3 git hostname lsof openssl procps

# Step 4: openclaw
echo ""
echo "[4/5] npm install -g openclaw@${OPENCLAW_VERSION}..."
npm config set registry https://registry.npmmirror.com
retry 3 npm install -g "openclaw@${OPENCLAW_VERSION}" || {
  echo "  阿里云镜像失败，切换官方源重试..."
  npm config set registry https://registry.npmjs.org
  retry 3 npm install -g "openclaw@${OPENCLAW_VERSION}"
}
echo "  openclaw 安装完成"
openclaw --version 2>/dev/null || true

# Step 5: 收集文件
echo ""
echo "[5/5] 收集文件..."
mkdir -p /output/payload/debs

# Node.js 运行时
for bin in node npm npx corepack; do
  [ -f "/usr/local/bin/$bin" ] && cp "/usr/local/bin/$bin" /output/payload/
done

# openclaw 全局安装
cp -a /usr/local/lib/node_modules/openclaw /output/payload/node_modules_openclaw
cp -a /usr/local/lib/node_modules/npm /output/payload/node_modules_npm
[ -d /usr/local/lib/node_modules/corepack ] && \
  cp -a /usr/local/lib/node_modules/corepack /output/payload/node_modules_corepack

# deb 包 (运行时依赖)
cp /var/cache/apt/archives/*.deb /output/payload/debs/

# 清理不必要文件减小体积
rm -rf /output/payload/node_modules_openclaw/docs 2>/dev/null || true
rm -rf /output/payload/node_modules_openclaw/test 2>/dev/null || true
rm -rf /output/payload/node_modules_openclaw/qa 2>/dev/null || true

echo ""
echo "============================================"
echo "  构建完成"
echo "============================================"
echo "  deb 包: $(ls /output/payload/debs/*.deb 2>/dev/null | wc -l) 个"
echo "  总大小: $(du -sh /output/payload/ | cut -f1)"
INNER_SCRIPT
)

# ─── 安装脚本 (写入包内) ─────────────────────────────────────
INSTALL_SCRIPT=$(cat <<'INSTALL_EOF'
#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  OpenClaw 离线安装 (ARM64 Ubuntu 20.04)"
echo "============================================"

if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  echo "错误：此安装包仅适用于 ARM64 架构" >&2; exit 1
fi
if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 运行: sudo bash install.sh" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"

echo ""
echo "[1/4] 安装系统依赖 (deb 包)..."
DEBS_DIR="$PAYLOAD/debs"
if [ -d "$DEBS_DIR" ] && ls "$DEBS_DIR"/*.deb >/dev/null 2>&1; then
  for pass in 1 2 3; do
    dpkg -i "$DEBS_DIR/"*.deb 2>/dev/null || true
  done
  dpkg --configure -a 2>/dev/null || true
  echo "  系统依赖安装完成"
else
  echo "  警告：未找到 deb 包，跳过"
fi

echo ""
echo "[2/4] 安装 Node.js 运行时..."
install -m 0755 "$PAYLOAD/node" /usr/local/bin/node
install -m 0755 "$PAYLOAD/npm" /usr/local/bin/npm
install -m 0755 "$PAYLOAD/npx" /usr/local/bin/npx
if [ -f "$PAYLOAD/corepack" ]; then
  install -m 0755 "$PAYLOAD/corepack" /usr/local/bin/corepack
fi
echo "  Node.js $(node -v) 已安装"

echo ""
echo "[3/4] 安装 OpenClaw..."
mkdir -p /usr/local/lib/node_modules
cp -a "$PAYLOAD/node_modules_openclaw" /usr/local/lib/node_modules/openclaw
cp -a "$PAYLOAD/node_modules_npm" /usr/local/lib/node_modules/npm
if [ -d "$PAYLOAD/node_modules_corepack" ]; then
  cp -a "$PAYLOAD/node_modules_corepack" /usr/local/lib/node_modules/corepack
fi
ln -sf ../lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw
chmod +x /usr/local/lib/node_modules/openclaw/openclaw.mjs
echo "  OpenClaw 已安装"

echo ""
echo "[4/4] 创建配置目录..."
mkdir -p ~/.openclaw/workspace

echo ""
echo "============================================"
echo "  安装完成！"
echo "============================================"
echo ""
echo "  验证:  openclaw --version"
echo "  配置:  cp openclaw.json ~/.openclaw/openclaw.json"
echo "  启动:  bash start-openclaw.sh"
echo ""
INSTALL_EOF
)

# ─── 启动脚本 (写入包内) ─────────────────────────────────────
START_SCRIPT=$(cat <<'START_EOF'
#!/bin/bash
# === 在此设置你的 OpenAI API Key ===
export OPENAI_API_KEY="sk-your-key-here"

# 启动 gateway
openclaw gateway --port 18789 --verbose
START_EOF
)

# ─── 默认配置 (写入包内) ─────────────────────────────────────
DEFAULT_CONFIG='{
  "agent": {
    "model": "openai/gpt-4o"
  }
}'

# ─── 主构建流程 ──────────────────────────────────────────────
cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  # 本地环境清理临时目录，GitHub Actions 由 runner 自动清理
  if [ -z "${GITHUB_ACTIONS:-}" ] && [ -n "${BUILD_DIR:-}" ] && [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

info "开始构建 OpenClaw 离线安装包"
info "平台: $PLATFORM | 基础镜像: $BASE_IMAGE | Node.js: v$NODE_MAJOR | OpenClaw: $OPENCLAW_VERSION"

# 拉取基础镜像
info "拉取基础镜像 $BASE_IMAGE ($PLATFORM)..."
docker pull --platform "$PLATFORM" "$BASE_IMAGE"

# 创建构建目录
BUILD_DIR=$(mktemp -d)
mkdir -p "$BUILD_DIR/payload/debs"

# 启动容器
info "启动构建容器..."
docker run --platform "$PLATFORM" --name "$CONTAINER_NAME" \
  -v "$BUILD_DIR/payload":/output/payload \
  -e NODE_MAJOR="$NODE_MAJOR" \
  -e OPENCLAW_VERSION="$OPENCLAW_VERSION" \
  -d "$BASE_IMAGE" sleep 3600

# 执行构建
info "在容器内执行构建 (这可能需要 10-20 分钟)..."
docker exec "$CONTAINER_NAME" bash -c "$BUILD_SCRIPT"

# 写入包内文件
info "写入安装脚本和配置..."
echo "$INSTALL_SCRIPT"  > "$BUILD_DIR/install.sh"
echo "$START_SCRIPT"    > "$BUILD_DIR/start-openclaw.sh"
echo "$DEFAULT_CONFIG"  > "$BUILD_DIR/openclaw.json"
chmod +x "$BUILD_DIR/install.sh" "$BUILD_DIR/start-openclaw.sh"

# 写入 README
cat > "$BUILD_DIR/README.txt" <<'README_EOF'
OpenClaw 离线安装包 (ARM64 Ubuntu 20.04)

安装:
  tar xzf openclaw-offline-arm64.tar.gz
  cd openclaw-offline-arm64
  sudo bash install.sh

配置:
  cp openclaw.json ~/.openclaw/openclaw.json
  编辑 start-openclaw.sh 填入 OPENAI_API_KEY

启动:
  bash start-openclaw.sh

验证:
  openclaw --version
README_EOF

# 打包
info "打包..."
PACKAGE_PATH="$OUTPUT_DIR/${PACKAGE_NAME}.tar.gz"
tar czf "$PACKAGE_PATH" -C "$BUILD_DIR" .

SIZE=$(ls -lh "$PACKAGE_PATH" | awk '{print $5}')
echo ""
info "========================================="
info "  构建完成!"
info "  输出: $PACKAGE_PATH"
info "  大小: $SIZE"
info "========================================="
