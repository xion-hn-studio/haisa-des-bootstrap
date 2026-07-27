# apt —— haisa-des 包管理器命令行（Debian apt 风格）
# 纯脚本包：无编译，把 apt 命令安装到 $PREFIX/bin/
# 依赖 bootstrap 已有的 bash/curl/tar/sha256sum/python3
PKG_NAME="apt"
PKG_VERSION="1.0.0"
PKG_SRC_URL="local://packages/apt/apt"
PKG_SRC_SHA256=""
PKG_SRC_DIR="apt-1.0.0"
PKG_DESC="haisa-des 包管理器命令行（update/install/remove/upgrade/search/show/hold/mirror/pip）"

# 纯脚本包：自建空源码目录占位（fetch_pkg 已拷贝脚本到 CACHE_DIR）
pkg_prepare_src() {
    mkdir -p "$SRC_DIR/$PKG_SRC_DIR"
}

pkg_build() {
    local bindir="$PKG_STAGE$PREFIX/bin"
    mkdir -p "$bindir"
    # 拷贝 apt 脚本（fetch_pkg 已通过 local:// 下载到 CACHE_DIR）
    install -m 755 "$CACHE_DIR/apt" "$bindir/apt"
    log "  apt: 已安装到 $bindir/apt"
}
