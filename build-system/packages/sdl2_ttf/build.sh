# sdl2_ttf —— TTF 字体渲染（pygame font 模块依赖）
PKG_NAME="sdl2_ttf"
PKG_VERSION="2.22.0"
PKG_SRC_URL="https://github.com/libsdl-org/SDL_ttf/releases/download/release-2.22.0/SDL2_ttf-2.22.0.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="SDL2_ttf-2.22.0"

pkg_build() {
    # SDL2_ttf 通过 pkg-config 找 sdl2 与 freetype2，已在工具链文件设置
    # harfbuzz 已禁用（freetype 构建时 --with-harfbuzz=no）
    gnu_configure \
        --with-sdl-prefix="$PREFIX" \
        --disable-harfbuzz
    make -j"$JOBS"
    stage_install
}
