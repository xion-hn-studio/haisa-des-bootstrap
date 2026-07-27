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

    # CMake 构建的 SDL2 不会生成 sdl2.pc（pkg-config 文件），
    # 但 SDL2_image/mixer/ttf 的 autotools configure 依赖 pkg-config 找 sdl2
    # 才能拿到 -I$PREFIX/include/SDL2 和 -L$PREFIX/lib -lSDL2。
    # 手写一份最小化的 sdl2.pc 到 staging，给后续 3 个子包用。
    local pc_dir="$PKG_STAGE$PREFIX/lib/pkgconfig"
    mkdir -p "$pc_dir"
    cat >"$pc_dir/sdl2.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: sdl2
Description: Simple DirectMedia Layer
Version: $PKG_VERSION
Libs: -L\${libdir} -lSDL2
Cflags: -I\${includedir}/SDL2
EOF

    # 手写 sdl2-config 脚本：pygame setup.py 通过 SDL_CONFIG 环境变量或
    # 默认 sdl2-config 名字查找 SDL2 配置工具（config_unix.py:222）。
    # CMake 不生成该脚本，需手写一份输出 cflags/libs，让 pygame 能找到 SDL2。
    #
    # 关键：脚本输出的 -I/-L 路径必须是 CI 主机能访问的 staging 路径，
    # 而非设备路径 $PREFIX（CI 主机不存在 /data/data/...）。
    # 通过 STAGE_DIR 环境变量覆盖 prefix：cross-env.sh 会 export STAGE_DIR，
    # 设备运行时 STAGE_DIR 为空，自动回退到 $PREFIX（设备路径）。
    local bin_dir="$PKG_STAGE$PREFIX/bin"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/sdl2-config" <<EOF
#!/bin/sh
# HaisaDes 手写的 sdl2-config（CMake 构建的 SDL2 不生成此脚本）
# STAGE_DIR 由 cross-env.sh 设置（CI 交叉编译时），设备运行时为空用 \$PREFIX
prefix="\${STAGE_DIR:-}$PREFIX"
exec_prefix="\${prefix}"
libdir="\${exec_prefix}/lib"
includedir="\${prefix}/include"

while [ \$# -gt 0 ]; do
    case \$1 in
        --version) echo "$PKG_VERSION" ;;
        --cflags)  echo "-I\${includedir}/SDL2" ;;
        --libs)    echo "-L\${libdir} -lSDL2" ;;
        --prefix)  echo "\${prefix}" ;;
        *) echo "Unknown option: \$1" >&2; exit 1 ;;
    esac
    shift
done
EOF
    chmod 0755 "$bin_dir/sdl2-config"
}
