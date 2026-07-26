# freetype —— 字体渲染库（SDL2_ttf 依赖）
PKG_NAME="freetype"
PKG_VERSION="2.13.3"
PKG_SRC_URL="https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="freetype-2.13.3"

pkg_build() {
    # harfbuzz 暂不引入（避免循环依赖：harfbuzz 反过来依赖 freetype）
    # bzip2 禁用：bzip2 仅用于 PCF 字体压缩，TTF/OTF 用不到；且 bzip2 无 .pc
    #   文件，freetype configure 在交叉编译时找不到库会报错（test variant 实测）
    gnu_configure \
        --with-harfbuzz=no \
        --with-bzip2=no \
        --with-png \
        --with-zlib
    make -j"$JOBS"
    stage_install
}
