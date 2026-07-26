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
    # png 禁用：libpng 装到 $PREFIX/include/libpng16/ 子目录，pkg-config 返回的
    #   cflags 是设备路径（非 staging 路径），CI 交叉编译时找不到 png.h。
    #   freetype 的 png 支持仅用于 sfnt 表彩色 emoji 字体（pngshim.c），
    #   pygame 用 TTF 不需要，安全禁用。
    #
    # 注意：仅传 --with-png=no 不够。freetype 的 pngshim.c 由 ftoption.h 中的
    #   FT_CONFIG_OPTION_USE_PNG 宏无条件定义控制（不随 configure 选项变化），
    #   pngshim.c 仍会编译并 #include <png.h>，导致 CI 上 'png.h file not found'。
    #   必须在 configure 前 sed 注释掉该宏，才能真正不编译 pngshim.c。
    sed -i 's|^\(#define FT_CONFIG_OPTION_USE_PNG\)|/* \1 */|' \
        include/freetype/config/ftoption.h
    gnu_configure \
        --with-harfbuzz=no \
        --with-bzip2=no \
        --with-png=no \
        --with-zlib
    make -j"$JOBS"
    stage_install
}
