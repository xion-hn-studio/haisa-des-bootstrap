# libmd —— BSD message digest 库（MD5/SHA/RIPEMD 等 BSD-style API）
# dpkg configure 用 AC_CHECK_LIB(md, MD5Init) 探测 BSD 风格的 MD5Init/MD5Update/MD5Final，
# Android bionic libc 不导出这些符号（只有 OpenSSL 的 MD5_Init 带下划线变体），
# dpkg 拒绝使用 OpenSSL API。libmd 提供 BSD 兼容包装，是 dpkg 的硬依赖。
PKG_NAME="libmd"
PKG_VERSION="1.1.0"
PKG_SRC_URL="https://deb.debian.org/debian/pool/main/libm/libmd/libmd_1.1.0.orig.tar.xz"
PKG_SRC_SHA256="1bd6aa42275313af3141c7cf2e5b964e8b1fd488025caf2f971f43b00776b332"
PKG_SRC_DIR="libmd-1.1.0"

pkg_build() {
    gnu_configure
    make -j"$JOBS"
    stage_install
}
