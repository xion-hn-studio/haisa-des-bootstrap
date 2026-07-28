# libpng —— PNG 解码库（SDL2_image / freetype 依赖）
PKG_NAME="libpng"
PKG_VERSION="1.6.44"
# 用 GitHub 镜像：sourceforge 链路在 CI 偶发 503
PKG_SRC_URL="https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.44.tar.gz"
PKG_SRC_SHA256="0ef5b633d0c65f780c4fced27ff832998e71478c13b45dfb6e94f23a82f64f7c"
PKG_SRC_DIR="libpng-1.6.44"

pkg_build() {
    # libpng configure 通过环境找 zlib；交叉编译时需显式指定 LDFLAGS
    export LDFLAGS="$LDFLAGS -lz"
    gnu_configure --disable-tools
    make -j"$JOBS"
    stage_install
}
