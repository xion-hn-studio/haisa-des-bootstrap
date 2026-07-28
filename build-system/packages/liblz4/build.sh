# liblz4 —— 快速 LZ 压缩库，apt 依赖
PKG_NAME="liblz4"
PKG_VERSION="1.10.0"
PKG_SRC_URL="https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz"
PKG_SRC_SHA256="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"
PKG_SRC_DIR="lz4-1.10.0"

pkg_build() {
    # liblz4 用 make + TARGET_TRIPLE 交叉编译
    # 跳过命令行工具（只装库和头文件）
    make -j"$JOBS" \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        BUILD_STATIC=no \
        PREFIX="$PREFIX" \
        -C lib install \
        DESTDIR="$PKG_STAGE"
}
