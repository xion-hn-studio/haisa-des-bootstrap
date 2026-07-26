# sdl2_image —— 图片加载库（pygame image 模块依赖）
PKG_NAME="sdl2_image"
PKG_VERSION="2.8.2"
PKG_SRC_URL="https://github.com/libsdl-org/SDL_image/releases/download/release-2.8.2/SDL2_image-2.8.2.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="SDL2_image-2.8.2"

pkg_build() {
    # PKG_CONFIG_PATH（工具链文件已设）= staging 的 pkgconfig
    # 禁用未引入的解码器：webp/tiff/jxl/avif 减少依赖
    # PNG/JPG 走默认 auto 检测（检测到 libpng/libjpeg 即启用）
    #
    # SDL2 用 CMake 构建，手写的 sdl2.pc 中 prefix=$PREFIX 是设备路径，
    # pkg-config 返回的 cflags 是设备路径（CI 主机不存在），导致编译时
    # 'SDL.h file not found'。直接覆盖 SDL_CFLAGS/SDL_LIBS 指向 staging，
    # 绕过 pkg-config 的 cflags 解析。
    export SDL_CFLAGS="-I$STAGE_DIR$PREFIX/include/SDL2"
    export SDL_LIBS="-L$STAGE_DIR$PREFIX/lib -lSDL2"
    gnu_configure \
        --disable-webp \
        --disable-tiff \
        --disable-jxl \
        --disable-avif
    make -j"$JOBS"
    stage_install
}
