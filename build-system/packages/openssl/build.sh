# openssl —— TLS 库（curl 依赖链第二层）
PKG_NAME="openssl"
PKG_VERSION="3.5.2"
PKG_SRC_URL="https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-3.5.2"
PKG_SRC_SHA256="ab2c26cc1ffead456bafdb920c90216a727a060d727b305e44f1e4f6dbf4c6cb"
PKG_SRC_DIR="openssl-openssl-3.5.2"

pkg_build() {
    # OPENSSL_TARGET 由工具链文件提供：ndk → android-arm64；termux-local → linux-aarch64
    ./Configure "$OPENSSL_TARGET" \
        -D__ANDROID_API__="$API_LEVEL" \
        shared no-tests \
        --prefix="$PREFIX" \
        --openssldir="$PREFIX/etc/ssl"
    make -j"$JOBS" build_sw
    make install_sw DESTDIR="$PKG_STAGE"
    mkdir -p "$PKG_STAGE$PREFIX/etc/ssl/certs" "$PKG_STAGE$PREFIX/etc/ssl/private"
}
