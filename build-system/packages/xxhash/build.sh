# xxhash —— 极快非加密哈希，apt 依赖
PKG_NAME="xxhash"
PKG_VERSION="0.8.3"
PKG_SRC_URL="https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz"
PKG_SRC_SHA256="aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80"
PKG_SRC_DIR="xxHash-0.8.3"

pkg_build() {
    # xxhash 用 make 交叉编译
    # XXH_FORCE_MEMORY_ACCESS=2：避免对齐访问问题（aarch64 兼容性）
    # LDFLAGS 加 -shared：Termux clang 不自动加共享库链接标志
    make -j"$JOBS" \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -shared" \
        XXH_FORCE_MEMORY_ACCESS=2 \
        BUILD_STATIC=no \
        PREFIX="$PREFIX" \
        lib \
        DESTDIR="$PKG_STAGE"
    # lib 目标构建 libxxhash.so；install 单独执行
    make -C lib install \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -shared" \
        PREFIX="$PREFIX" \
        DESTDIR="$PKG_STAGE"
}
