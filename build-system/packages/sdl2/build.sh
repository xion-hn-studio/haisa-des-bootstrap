# SDL2 —— 图形/事件核心库（pygame 依赖链根）
PKG_NAME="sdl2"
PKG_VERSION="2.30.10"
PKG_SRC_URL="https://github.com/libsdl-org/SDL/releases/download/release-2.30.10/SDL2-2.30.10.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="SDL2-2.30.10"

pkg_build() {
    # 用 CMake + NDK 官方工具链构建（SDL2 推荐方式，autotools 在 Android 交叉编译
    # 时遇到 joystick/haptic 平台代码 #ifdef 处理问题，CMake 更可靠）。
    #
    # 禁用所有桌面后端（Wayland/X11/ALSA/PulseAudio 等），仅保留 OpenGL ES 2 +
    # OpenSLES 音频 + Android 平台代码。pygame headless 模式下不依赖视频后端。
    #
    # 关键选项：
    # - SDL_OPENGLES=ON：aarch64 Android 用 OpenGL ES 2
    # - SDL_OPENSL_ES（自动）：Android 系统音频后端，NDK sysroot 中 libOpenSLES.so 存在
    # - SDL_JOYSTICK/HIDAPI 默认 ON：SDL_android.c 引用 joystick 回调，
    #   禁用会引发 Android_OnPadDown 等函数未声明错误（SDL 2.30 #ifdef 不完整）
    cmake -B build -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="arm64-v8a" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DANDROID_STL="c++_static" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR="lib" \
        -DCMAKE_FIND_ROOT_PATH="$STAGE_DIR$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM="NEVER" \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY="ONLY" \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE="ONLY" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE="ONLY" \
        -DSDL_STATIC=OFF \
        -DSDL_SHARED=ON \
        -DSDL_TEST=OFF \
        -DSDL_OPENGL=OFF \
        -DSDL_OPENGLES=ON \
        -DSDL_VULKAN=OFF \
        -DSDL_VIDEO_WAYLAND=OFF \
        -DSDL_VIDEO_X11=OFF \
        -DSDL_VIDEO_OFFSCREEN=OFF \
        -DSDL_VIDEO_DUMMY=OFF \
        -DSDL_VIDEO_VITA_PVR=OFF \
        -DSDL_AUDIO=ON \
        -DSDL_ALSA=OFF \
        -DSDL_JACK=OFF \
        -DSDL_PULSEAUDIO=OFF \
        -DSDL_ESD=OFF \
        -DSDL_NAS=OFF \
        -DSDL_SNDIO=OFF \
        -DSDL_DISKAUDIO=OFF \
        -DSDL_DUMMYAUDIO=OFF \
        -DSDL_LIBSAMPLERATE=OFF \
        -DSDL_INPUT_LINUXEV=OFF \
        -DSDL_INPUT_LINUXKD=OFF \
        -DSDL_DIRECTFB=OFF \
        -DSDL_IBUS=OFF \
        -DSDL_FCITX=OFF \
        -DSDL_OPENGL=OFF
    cmake --build build -j"$JOBS"
    DESTDIR="$PKG_STAGE" cmake --install build
    # sdl2-config 是 shell 脚本（被 SDL2_image/mixer/ttf 的 configure 调用），
    # 内部硬编码了 $PREFIX/bin/sdl2-config 路径，无需特殊处理
}
