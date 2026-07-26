# zlib —— 底层压缩库（curl 依赖链第一层）
PKG_NAME="zlib"
PKG_VERSION="1.3.1"
# 用 GitHub 镜像：zlib.net 对云机房 IP 间歇性返回 415（CI 实测）
PKG_SRC_URL="https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v1.3.1"
PKG_SRC_SHA256="17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c"
PKG_SRC_DIR="zlib-1.3.1"

pkg_build() {
    # lld ≥16 默认 --no-undefined-version：zlib configure 的共享库探测链接只有
    # 单个测试 .o，version script 引用的符号尚未定义 → 误判“无共享支持”只产静态库。
    # 注意：该探测命令只用 CFLAGS 不用 LDFLAGS，所以必须加进 CFLAGS。
    export CFLAGS="$CFLAGS -Wl,--undefined-version"
    # zlib 的 configure 非 autoconf，不支持 --host，直接读 CC/CFLAGS 环境
    ./configure --prefix="$PREFIX" --shared
    make -j"$JOBS"
    stage_install
}
