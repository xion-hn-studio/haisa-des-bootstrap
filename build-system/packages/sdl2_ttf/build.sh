# sdl2_ttf —— TTF 字体渲染（pygame font 模块依赖）
PKG_NAME="sdl2_ttf"
PKG_VERSION="2.22.0"
PKG_SRC_URL="https://github.com/libsdl-org/SDL_ttf/releases/download/release-2.22.0/SDL2_ttf-2.22.0.tar.gz"
PKG_SRC_SHA256="0131c57d44ed8847d4956b3a4bf07959d27ff0c443d468c95eac66b5bb79d9a0"
PKG_SRC_DIR="SDL2_ttf-2.22.0"

pkg_build() {
    # SDL2_ttf 通过 pkg-config 找 sdl2 与 freetype2，已在工具链文件设置
    # harfbuzz 已禁用（freetype 构建时 --with-harfbuzz=no）
    #
    # 不能传 --with-sdl-prefix：sdl2.m4 中传该参数会跳过 pkg-config，转而用
    # $sdl_prefix/bin/sdl2-config（设备路径，CI 主机不存在），导致 configure 失败。
    # 同 sdl2_image/mixer：不传 prefix，让 pkg-config 检测 SDL；SDL_CFLAGS/SDL_LIBS
    # 覆盖 pkg-config 返回的设备路径 cflags。
    export SDL_CFLAGS="-I$STAGE_DIR$PREFIX/include/SDL2"
    export SDL_LIBS="-L$STAGE_DIR$PREFIX/lib -lSDL2"
    gnu_configure \
        --disable-harfbuzz \
        --disable-examples
    # 同 sdl2_image：sdl2_ttf 2.22 用 automake，PROGRAMS=$(noinst_PROGRAMS)，
    # 命令行传 noinst_PROGRAMS= 覆盖即可跳过 glfont/showfont 示例
    # （Android 上 main 被 SDL_main 宏吃掉，链接报 undefined symbol: main）
    make -j"$JOBS" noinst_PROGRAMS=
    stage_install noinst_PROGRAMS=
}
