# freetype —— 字体渲染库（SDL2_ttf 依赖）
PKG_NAME="freetype"
PKG_VERSION="2.13.3"
PKG_SRC_URL="https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="freetype-2.13.3"

pkg_build() {
    # harfbuzz 暂不引入（避免循环依赖：harfbuzz 反过来依赖 freetype）
    gnu_configure \
        --with-harfbuzz=no \
        --with-bzip2 \
        --with-png \
        --with-zlib
    make -j"$JOBS"
    stage_install
}
