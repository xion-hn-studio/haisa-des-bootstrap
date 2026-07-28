# libjpeg-turbo —— JPEG 解码库（SDL2_image 依赖）
PKG_NAME="libjpeg-turbo"
PKG_VERSION="3.0.4"
PKG_SRC_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.4/libjpeg-turbo-3.0.4.tar.gz"
PKG_SRC_SHA256="99130559e7d62e8d695f2c0eaeef912c5828d5b84a0537dcb24c9678c9d5b76b"
PKG_SRC_DIR="libjpeg-turbo-3.0.4"

pkg_build() {
    # 使用 NDK 官方 CMake 工具链文件，自动配置交叉编译环境
    # ANDROID_NDK_HOME 在工具链 ndk-r29.sh 中已 export
    # NASM 在 aarch64 交叉时无意义且宿主未必装
    cmake -B build -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="arm64-v8a" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DANDROID_STL="none" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR="lib" \
        -DWITH_SIMD=OFF \
        -DENABLE_SHARED=ON \
        -DENABLE_STATIC=OFF \
        -DWITH_JAVA=OFF \
        -DCMAKE_FIND_ROOT_PATH="$STAGE_DIR$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM="NEVER" \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY="ONLY" \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE="ONLY" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE="ONLY"
    cmake --build build -j"$JOBS"
    # CMAKE_INSTALL_PREFIX 已在配置时设为 $PREFIX；
    # 通过 DESTDIR 环境变量让 install 落到单包 staging
    DESTDIR="$PKG_STAGE" cmake --install build
}
