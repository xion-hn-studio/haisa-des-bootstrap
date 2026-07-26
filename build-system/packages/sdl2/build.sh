# SDL2 —— 图形/事件核心库（pygame 依赖链根）
PKG_NAME="sdl2"
PKG_VERSION="2.30.10"
PKG_SRC_URL="https://github.com/libsdl-org/SDL/releases/download/release-2.30.10/SDL2-2.30.10.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="SDL2-2.30.10"

pkg_build() {
    # 禁用所有桌面 Linux 后端（Wayland/X11/ALSA/PulseAudio 等），
    # 仅保留 OpenGL ES 2 + 内核 evdev 触摸/输入。Android 实际渲染由 App 侧
    # 通过 SDL_OpenGLES + ANativeWindow 完成，但 pygame headless 模式下不依赖视频后端。
    gnu_configure \
        --disable-video-wayland \
        --disable-video-x11 \
        --disable-video-vulkan \
        --enable-video-opengles2 \
        --disable-video-offscreen \
        --disable-video-dummy \
        --disable-alsa \
        --disable-jack \
        --disable-pulseaudio \
        --disable-esd \
        --disable-arts \
        --disable-nas \
        --disable-sndio \
        --disable-fusionsound \
        --disable-diskaudio \
        --disable-dummyaudio \
        --disable-libsamplerate \
        --disable-ime \
        --disable-ibus \
        --disable-fcitx \
        --disable-directfb
    make -j"$JOBS"
    stage_install
    # sdl2-config 是 shell 脚本（被 SDL2_image/mixer/ttf 的 configure 调用），
    # 内部硬编码了 $PREFIX/bin/sdl2-config 路径，无需特殊处理
}
