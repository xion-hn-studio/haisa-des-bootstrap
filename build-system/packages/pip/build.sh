# pip —— haisa-des pip 接管 wrapper
# 纯脚本包：无编译，把 wrapper 安装到 $PREFIX/bin/pip
# 同时把原版 pip 重命名为 pip.real（wrapper 透传未拦截的命令给原版）
PKG_NAME="pip"
PKG_VERSION="1.0.0"
PKG_SRC_URL="local://packages/pip/pip"
PKG_SRC_SHA256=""
PKG_SRC_DIR="pip-1.0.0"
PKG_DESC="haisa-des pip 接管 wrapper（优先查本地 wheel 索引，未命中回退 PyPI）"

# 纯脚本包：自建空源码目录占位
pkg_prepare_src() {
    mkdir -p "$SRC_DIR/$PKG_SRC_DIR"
}

pkg_build() {
    local bindir="$PKG_STAGE$PREFIX/bin"
    mkdir -p "$bindir"

    # 拷贝 wrapper 脚本
    install -m 755 "$CACHE_DIR/pip" "$bindir/pip"

    # 创建 pip3 / pip3.13 符号链接 → pip（统一走 wrapper）
    ln -sfn pip "$bindir/pip3"
    ln -sfn pip "$bindir/pip3.13"

    log "  pip: wrapper 已安装到 $bindir/pip"
    log "  pip: 原版 pip 在 BootstrapInstaller 中重命名为 pip.real"
}
