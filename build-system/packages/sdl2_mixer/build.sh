# sdl2_mixer —— 音频混音库（pygame mixer 模块依赖）
PKG_NAME="sdl2_mixer"
PKG_VERSION="2.8.0"
PKG_SRC_URL="https://github.com/libsdl-org/SDL_mixer/releases/download/release-2.8.0/SDL2_mixer-2.8.0.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="SDL2_mixer-2.8.0"

pkg_build() {
    # 禁用所有外部解码库（mp3/ogg/flac/mod），仅保留核心混音；
    # 用户后续需要这些可单独引入 libvorbis/libmodplug 后重新构建
    #
    # SDL_CFLAGS/SDL_LIBS 同 sdl2_image：覆盖 pkg-config 的设备路径 cflags。
    export SDL_CFLAGS="-I$STAGE_DIR$PREFIX/include/SDL2"
    export SDL_LIBS="-L$STAGE_DIR$PREFIX/lib -lSDL2"
    gnu_configure \
        --disable-music-mp3 \
        --disable-music-ogg \
        --disable-music-flac \
        --disable-music-mod \
        --disable-music-opus \
        --disable-music-midi \
        --disable-examples
    # 同 sdl2_image：跳过 playwave/playmus 示例（Android 上 main 被 SDL_main 宏吃掉）
    # SDL2_mixer 2.8 Makefile.am 用硬编码 noinst_PROGRAMS = build/playwave build/playmus
    # noinst_PROGRAMS= 变量覆盖无效，sed -d 删除行会破坏 Makefile 结构（recipe 无目标）。
    # 用 sed s||| 把 noinst_PROGRAMS 赋值行替换为空，只改变量值不破坏规则。
    sed -i 's|^noinst_PROGRAMS = .*|noinst_PROGRAMS =|' Makefile
    make -j"$JOBS"
    stage_install
}
