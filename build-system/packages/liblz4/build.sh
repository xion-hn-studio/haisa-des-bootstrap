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

    # 显式确保 liblz4.so / liblz4.so.1 软链接存在
    # lz4 的 Makefile install 在某些情况下不装 .so（只装 .so.x.y.z），
    # 导致下游 find_library(NAMES lz4) 找不到 liblz4.so →
    # CMake FindLZ4 报 "missing: LZ4_LIBRARIES"（即使 .so.1 存在）。
    local libdir="$PKG_STAGE$PREFIX/lib"
    local real_so
    real_so=$(ls "$libdir"/liblz4.so.*.*.* 2>/dev/null | head -1)
    if [ -n "$real_so" ] && [ ! -e "$libdir/liblz4.so" ]; then
        ln -sf "$(basename "$real_so")" "$libdir/liblz4.so"
        log "liblz4: 创建 liblz4.so 软链接 → $(basename "$real_so")"
    fi
    if [ -n "$real_so" ] && [ ! -e "$libdir/liblz4.so.1" ]; then
        ln -sf "$(basename "$real_so")" "$libdir/liblz4.so.1"
        log "liblz4: 创建 liblz4.so.1 软链接 → $(basename "$real_so")"
    fi
}
