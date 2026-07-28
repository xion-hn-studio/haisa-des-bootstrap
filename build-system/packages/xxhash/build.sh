# xxhash —— 极快非加密哈希，apt 依赖
PKG_NAME="xxhash"
PKG_VERSION="0.8.3"
PKG_SRC_URL="https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz"
PKG_SRC_SHA256="aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80"
PKG_SRC_DIR="xxHash-0.8.3"

pkg_build() {
    # xxhash 0.8.3 顶层 Makefile 的 `lib` 是 .PHONY 目标（先决条件 libxxhash.a + libxxhash），
    # 在 -j 并行模式下偶发 "make: *** lib: No such file or directory. Stop." 误报退出 2。
    # 改用真实文件目标 libxxhash.a + libxxhash.so.<ver>（即 Makefile 内 $(LIBXXH)）规避。
    # XXH_FORCE_MEMORY_ACCESS=2：避免对齐访问问题（aarch64 兼容性）
    # LDFLAGS 加 -shared：clang 不自动加共享库链接标志
    local soname="libxxhash.so.${PKG_VERSION}"
    make -j"$JOBS" \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -shared" \
        XXH_FORCE_MEMORY_ACCESS=2 \
        BUILD_STATIC=no \
        PREFIX="$PREFIX" \
        libxxhash.a "$soname"

    # 安装静态库 + 头文件 + pkgconfig（这三个 install_* 目标都不依赖 .PHONY libxxhash）
    make install_libxxhash.a install_libxxhash.includes install_libxxhash.pc \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -shared" \
        PREFIX="$PREFIX" \
        DESTDIR="$PKG_STAGE"

    # install_libxxhash 依赖 .PHONY libxxhash，绕开：手动安装 .so + soname 符号链接
    install -d -m 755 "$PKG_STAGE$PREFIX/lib"
    install -m 755 "$soname" "$PKG_STAGE$PREFIX/lib/"
    ln -sf "$soname" "$PKG_STAGE$PREFIX/lib/libxxhash.so.0"
    ln -sf "$soname" "$PKG_STAGE$PREFIX/lib/libxxhash.so"
}
