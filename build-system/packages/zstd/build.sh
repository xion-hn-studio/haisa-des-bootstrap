# zstd —— Zstandard 压缩库，apt 依赖
PKG_NAME="zstd"
PKG_VERSION="1.5.7"
PKG_SRC_URL="https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz"
PKG_SRC_SHA256="37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3"
PKG_SRC_DIR="zstd-1.5.7"

pkg_build() {
    # zstd 用 make 交叉编译，只装 lib（含头文件）
    # HAVE_ZLIB=0 / HAVE_LZMA=0 / HAVE_LZ4=0：避免探测宿主库（我们是交叉编译，探测到的宿主库不兼容）
    make -j"$JOBS" \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -shared" \
        HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 \
        BUILD_STATIC=no \
        PREFIX="$PREFIX" \
        -C lib install \
        DESTDIR="$PKG_STAGE"
}
