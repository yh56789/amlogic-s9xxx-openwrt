#!/bin/bash
#========================================================================================================================
# 本地执行脚本：build-openwrt-system-image.yml 的本地等价实现
# 功能：编译 OpenWrt 固件并打包为可刷写镜像
# 对应工作流：.github/workflows/build-openwrt-system-image.yml
#========================================================================================================================

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 默认参数（与工作流一致）
DEFAULT_SOURCE_BRANCH="immortalwrt_master"
DEFAULT_OPENWRT_BOARD="nsy-g68-plus"
DEFAULT_OPENWRT_KERNEL="6.18.y"
DEFAULT_AUTO_KERNEL="true"
DEFAULT_KERNEL_REPO="ophub/kernel"
DEFAULT_KERNEL_USAGE="stable"
DEFAULT_OPENWRT_IP="192.168.1.1"
DEFAULT_USE_CCACHE="true"
DEFAULT_OPENWRT_STORAGE="save"
DEFAULT_BUILDER_NAME=""

# 仓库路径
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"
BUILD_DIR="${REPO_ROOT}/openwrt-build"

# 显示帮助信息
show_help() {
    cat <<-EOF
用法: $0 [选项]

此脚本是 GitHub Actions 工作流 build-openwrt-system-image.yml 的本地等价实现。
它将编译 OpenWrt 固件并打包为 Amlogic/Rockchip/Allwinner 盒子可用的镜像。

选项:
  -b BOARD          目标设备板型 (默认: $DEFAULT_OPENWRT_BOARD)
  -s SOURCE_BRANCH  源码分支 (默认: $DEFAULT_SOURCE_BRANCH)
                    可选: openwrt_main, lede_master, immortalwrt_master, all
  -k KERNEL         内核版本 (默认: $DEFAULT_OPENWRT_KERNEL)
                    例如: 6.18.y 或 6.1.y_6.18.y (双内核)
  -a AUTO_KERNEL    自动使用最新内核 (默认: $DEFAULT_AUTO_KERNEL)
                    true/false
  -r KERNEL_REPO    内核仓库 (默认: $DEFAULT_KERNEL_REPO)
  -u KERNEL_USAGE   内核标签 (默认: $DEFAULT_KERNEL_USAGE)
  -p IP             OpenWrt 默认 IP (默认: $DEFAULT_OPENWRT_IP)
  -c USE_CCACHE     使用 ccache 加速 (默认: $DEFAULT_USE_CCACHE)
                    true/false
  -t STORAGE        存储类型 (默认: $DEFAULT_OPENWRT_STORAGE)
                    save/backup/emmc
  -n BUILDER_NAME   构建者签名 (默认: 空)
  -h                显示此帮助信息

示例:
  $0                                    # 使用默认参数
  $0 -b r66s -k 6.1.y_6.18.y          # 为 r66s 编译双内核版本
  $0 -s openwrt_main -p 192.168.2.1   # 编译 OpenWrt 官方分支，自定义 IP

重要提示:
  1. 当前机器为 x86_64，固件目标为 ARM64，将进行交叉编译
  2. 编译需要较大的磁盘空间（建议 >50GB）和较长时间（1-4 小时）
  3. 首次运行需要安装编译依赖，可能需要输入 sudo 密码
  4. remake 打包需要 root 权限，请提前配置 sudo 免密或准备好密码
EOF
}

# 解析命令行参数
SOURCE_BRANCH="$DEFAULT_SOURCE_BRANCH"
OPENWRT_BOARD="$DEFAULT_OPENWRT_BOARD"
OPENWRT_KERNEL="$DEFAULT_OPENWRT_KERNEL"
AUTO_KERNEL="$DEFAULT_AUTO_KERNEL"
KERNEL_REPO="$DEFAULT_KERNEL_REPO"
KERNEL_USAGE="$DEFAULT_KERNEL_USAGE"
OPENWRT_IP="$DEFAULT_OPENWRT_IP"
USE_CCACHE="$DEFAULT_USE_CCACHE"
OPENWRT_STORAGE="$DEFAULT_OPENWRT_STORAGE"
BUILDER_NAME="$DEFAULT_BUILDER_NAME"

while getopts "b:s:k:a:r:u:p:c:t:n:h" opt; do
    case $opt in
        b) OPENWRT_BOARD="$OPTARG" ;;
        s) SOURCE_BRANCH="$OPTARG" ;;
        k) OPENWRT_KERNEL="$OPTARG" ;;
        a) AUTO_KERNEL="$OPTARG" ;;
        r) KERNEL_REPO="$OPTARG" ;;
        u) KERNEL_USAGE="$OPTARG" ;;
        p) OPENWRT_IP="$OPTARG" ;;
        c) USE_CCACHE="$OPTARG" ;;
        t) OPENWRT_STORAGE="$OPTARG" ;;
        n) BUILDER_NAME="$OPTARG" ;;
        h) show_help; exit 0 ;;
        \?) log_error "无效选项: -$OPTARG"; show_help; exit 1 ;;
    esac
done

# 显示配置信息
log_info "构建配置："
echo "  源码分支: $SOURCE_BRANCH"
echo "  目标板型: $OPENWRT_BOARD"
echo "  内核版本: $OPENWRT_KERNEL"
echo "  自动内核: $AUTO_KERNEL"
echo "  内核仓库: $KERNEL_REPO"
echo "  内核标签: $KERNEL_USAGE"
echo "  默认 IP:  $OPENWRT_IP"
echo "  使用 ccache: $USE_CCACHE"
echo "  存储类型: $OPENWRT_STORAGE"
echo "  构建者:   ${BUILDER_NAME:-无}"
echo ""

# 检查依赖
log_info "检查编译依赖..."
DEPS=("git" "build-essential" "libncurses5-dev" "gawk" "gettext" "unzip" "file" "wget" "python3" "python3-setuptools" "rsync" "curl" "jq" "flex" "bison" "libssl-dev")
MISSING_DEPS=()

for dep in "${DEPS[@]}"; do
    if ! dpkg -l | grep -q "^ii  $dep"; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    log_warn "缺少以下依赖包: ${MISSING_DEPS[*]}"
    read -p "是否自动安装? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "安装编译依赖..."
        sudo apt update
        sudo apt install -y "${MISSING_DEPS[@]}"
    else
        log_error "请先安装缺失的依赖包"
        exit 1
    fi
fi

# 检查磁盘空间
log_info "检查磁盘空间..."
AVAILABLE_SPACE=$(df -BG "$REPO_ROOT" | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$AVAILABLE_SPACE" -lt 50 ]; then
    log_warn "可用磁盘空间不足 50GB (当前: ${AVAILABLE_SPACE}GB)，编译可能失败"
fi

# 检查是否为交叉编译
if [[ "$(uname -m)" == "x86_64" && "$OPENWRT_BOARD" != *"x86"* ]]; then
    log_info "检测到 x86_64 宿主机编译 ARM64 固件，将自动进行交叉编译"
    # 安装交叉编译工具链
    if ! dpkg -l | grep -q "gcc-aarch64-linux-gnu"; then
        log_info "安装交叉编译工具链..."
        sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
    fi
fi

# 处理 "all" 分支选项
if [[ "$SOURCE_BRANCH" == "all" ]]; then
    SOURCE_BRANCHES=("openwrt_main" "lede_master" "immortalwrt_master")
else
    SOURCE_BRANCHES=("$SOURCE_BRANCH")
fi

# 编译循环
for BRANCH in "${SOURCE_BRANCHES[@]}"; do
    log_info "开始编译 $BRANCH 分支..."
    
    # 设置源码仓库映射
    case $BRANCH in
        "openwrt_main")
            REPO_URL="https://github.com/openwrt/openwrt"
            BRANCH_NAME="main"
            CONFIG_PATH="$CONFIG_DIR/openwrt_main"
            ;;
        "lede_master")
            REPO_URL="https://github.com/coolsnowwolf/lede"
            BRANCH_NAME="master"
            CONFIG_PATH="$CONFIG_DIR/lede_master"
            ;;
        "immortalwrt_master")
            REPO_URL="https://github.com/immortalwrt/immortalwrt"
            BRANCH_NAME="master"
            CONFIG_PATH="$CONFIG_DIR/immortalwrt_master"
            ;;
        *)
            log_error "不支持的源码分支: $BRANCH"
            continue
            ;;
    esac
    
    # 创建构建目录
    BUILD_PATH="$BUILD_DIR/$BRANCH"
    mkdir -p "$BUILD_PATH"
    cd "$BUILD_PATH"
    
    # 克隆源码
    log_info "克隆 $BRANCH 源码..."
    if [ -d "openwrt" ]; then
        log_info "更新现有源码..."
        cd openwrt
        git fetch --depth 1 origin "$BRANCH_NAME"
        git checkout "$BRANCH_NAME"
        git pull
    else
        git clone --depth 1 -b "$BRANCH_NAME" "$REPO_URL" openwrt
        cd openwrt
    fi
    
    # 获取源码 commit hash
    COMMIT_HASH=$(git rev-parse --short HEAD)
    log_info "源码 commit: $COMMIT_HASH"
    
    # 应用配置文件
    log_info "应用配置文件..."
    cp -f "$CONFIG_PATH/config" .config
    cp -f "$CONFIG_PATH/diy-part1.sh" .
    cp -f "$CONFIG_PATH/diy-part2.sh" .
    cp -f "$CONFIG_DIR/feeds.conf.default" . 2>/dev/null || true
    
    # 运行 diy-part1.sh
    log_info "运行 diy-part1.sh..."
    bash diy-part1.sh
    
    # 更新 feeds
    log_info "更新 feeds..."
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    
    # 运行 diy-part2.sh
    log_info "运行 diy-part2.sh..."
    bash diy-part2.sh "$OPENWRT_IP" "$USE_CCACHE"
    
    # 配置编译
    log_info "配置编译选项..."
    make defconfig
    
    # 下载源码包
    log_info "下载源码包..."
    make download -j8
    find dl/ -size -1024c -exec rm -f {} \;
    
    # 编译
    log_info "开始编译 (这可能需要较长时间)..."
    CPU_COUNT=$(nproc)
    BUILD_JOBS=$((CPU_COUNT + 1))
    log_info "使用 $BUILD_JOBS 个并行任务"
    
    # 尝试并行编译，失败则降级
    if ! make -j"$BUILD_JOBS" V=s; then
        log_warn "并行编译失败，尝试单线程编译..."
        if ! make -j1 V=s; then
            log_error "编译失败"
            exit 1
        fi
    fi
    
    # 查找编译产物
    log_info "查找编译产物..."
    ROOTFS_FILE=$(find bin/targets -name "*rootfs.tar.gz" | head -1)
    if [ -z "$ROOTFS_FILE" ]; then
        log_error "未找到编译产物 rootfs.tar.gz"
        exit 1
    fi
    log_info "找到编译产物: $ROOTFS_FILE"
    
    # 打包固件
    log_info "打包固件..."
    cd "$REPO_ROOT"
    
    # 准备工作目录
    mkdir -p openwrt-armsr openwrt/out
    cp "$BUILD_PATH/openwrt/$ROOTFS_FILE" openwrt-armsr/
    
    # 构建 remake 参数
    REMAKE_ARGS=("-b" "$OPENWRT_BOARD" "-r" "$KERNEL_REPO" "-u" "$KERNEL_USAGE" "-k" "$OPENWRT_KERNEL" "-a" "$AUTO_KERNEL" "-p" "$OPENWRT_IP")
    [[ -n "$BUILDER_NAME" ]] && REMAKE_ARGS+=("-n" "$BUILDER_NAME")
    
    # 运行打包
    log_info "运行 remake 打包工具..."
    log_warn "此步骤可能需要 sudo 权限"
    sudo ./remake "${REMAKE_ARGS[@]}"
    
    # 显示结果
    if [ -d "openwrt/out" ] && [ "$(ls -A openwrt/out)" ]; then
        log_info "打包完成！输出文件："
        ls -lh openwrt/out/
    else
        log_error "打包失败"
        exit 1
    fi
    
done

log_info "所有构建任务完成！"
log_info "输出目录: $REPO_ROOT/openwrt/out"
