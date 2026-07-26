# sdl2_ttf —— TTF 字体渲染（pygame font 模块依赖）
PKG_NAME="sdl2_ttf"
PKG_VERSION="2.22.0"
PKG_SRC_URL="https://github.com/libsdl-org/SDL_ttf/releases/download/release-2.22.0/SDL2_ttf-2.22.0.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="SDL2_ttf-2.22.0"

pkg_build() {
    # SDL2_ttf 通过 pkg-config 找 sdl2 与 freetype2，已在工具链文件设置
    # harfbuzz 已禁用（freetype 构建时 --with-harfbuzz=no）
    #
    # SDL_CFLAGS/SDL_LIBS 同 sdl2_image：覆盖 pkg-config 的设备路径 cflags。
    export SDL_CFLAGS="-I$STAGE_DIR$PREFIX/include/SDL2"
    export SDL_LIBS="-L$STAGE_DIR$PREFIX/lib -lSDL2"
    gnu_configure \
        --with-sdl-prefix="$PREFIX" \
        --disable-harfbuzz \
        --disable-examples
    # 同 sdl2_image：sdl2_ttf 2.22 用 automake，PROGRAMS=$(noinst_PROGRAMS)，
    # 命令行传 noinst_PROGRAMS= 覆盖即可跳过 glfont/showfont 示例
    # （Android 上 main 被 SDL_main 宏吃掉，链接报 undefined symbol: main）
    make -j"$JOBS" noinst_PROGRAMS=
    stage_install noinst_PROGRAMS=
}
