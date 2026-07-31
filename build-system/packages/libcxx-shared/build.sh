# libcxx-shared —— NDK r29 的 libc++_shared.so（C++ STL 运行时）
#
# 背景:
#   apt 用 NDK clang++ 编译，动态链接 libc++_shared.so，其符号在 __ndk1 namespace
#   （如 _ZTTNSt6__ndk118basic_stringstreamI...E），与 Android 系统自带的
#   /system/lib64/libc++.so（_ZNSt3... namespace）ABI 不兼容。
#   设备端运行 apt 时若 bootstrap 未自带 libc++_shared.so，链接器回退到系统 libc++.so，
#   导致 "CANNOT LINK EXECUTABLE: cannot locate symbol _ZTTNSt6__ndk1..."。
#
#   本包直接从 NDK sysroot 拷贝预编译的 libc++_shared.so 到 $PREFIX/lib，
#   让所有 NDK 编译的 C++ 程序（apt/sdl2 等）通过 RUNPATH=$PREFIX/lib 找到正确的 STL。
#
# 无源码下载（PKG_SRC_URL 用 local:// 占位，pkg_prepare_src 跳过 extract）
PKG_NAME="libcxx-shared"
# Debian 版本号必须以数字开头（dpkg-deb -f 校验），去掉 NDK 版本的 'r' 前缀
PKG_VERSION="29.0.14206865"
PKG_SRC_URL="local://packages/libcxx-shared/.placeholder"
PKG_SRC_SHA256=""
PKG_SRC_DIR="libcxx-shared"

# 占位文件让 fetch_pkg 不报错（实际不使用）
# 创建空源码目录（build.sh 会 cd $SRC_DIR/$PKG_SRC_DIR 后调用 pkg_build）
pkg_prepare_src() {
    mkdir -p "$SRC_DIR/$PKG_SRC_DIR"
}

pkg_build() {
    # 从 NDK sysroot 拷贝预编译的 libc++_shared.so
    # 路径: $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/<triple>/libc++_shared.so
    local ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK:-$ANDROID_NDK_ROOT}}"
    [ -n "$ndk" ] && [ -d "$ndk" ] || die "libcxx-shared: ANDROID_NDK_HOME 未设置"
    local prebuilt="$ndk/toolchains/llvm/prebuilt/linux-x86_64"
    [ -d "$prebuilt" ] || prebuilt="$ndk/toolchains/llvm/prebuilt/windows-x86_64"
    [ -d "$prebuilt" ] || die "libcxx-shared: NDK prebuilt 不存在: $prebuilt"
    local src="$prebuilt/sysroot/usr/lib/$TARGET_TRIPLE/libc++_shared.so"
    [ -f "$src" ] || die "libcxx-shared: NDK 未提供 libc++_shared.so: $src"

    install -d -m 755 "$PKG_STAGE$PREFIX/lib"
    install -m 755 "$src" "$PKG_STAGE$PREFIX/lib/libc++_shared.so"

    log "libcxx-shared: 拷贝 NDK libc++_shared.so ($(stat -c%s "$src") bytes)"
    log "  SONAME: $(readelf -d "$src" 2>/dev/null | awk '/SONAME/ {print $NF}')"
}
