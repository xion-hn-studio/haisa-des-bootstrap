# curl —— HTTP 客户端，本 demo 的核心验证包（curl → openssl → zlib 三层 RUNPATH 链）
PKG_NAME="curl"
PKG_VERSION="8.14.1"
PKG_SRC_URL="https://curl.se/download/curl-8.14.1.tar.gz"
PKG_SRC_SHA256="6766ada7101d292b42b8b15681120acd68effa4a9660935853cf6d61f0d984d4"
PKG_SRC_DIR="curl-8.14.1"

pkg_build() {
    gnu_configure \
        --with-openssl="$STAGE_DIR$PREFIX" \
        --with-zlib="$STAGE_DIR$PREFIX" \
        --with-ca-bundle="$PREFIX/etc/ssl/certs/ca-certificates.crt" \
        --with-ca-path="$PREFIX/etc/ssl/certs" \
        --without-libpsl --without-nghttp2 --without-ngtcp2 --without-nghttp3 \
        --without-brotli --without-zstd --without-libidn2 --without-libssh2 \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
        --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
        --disable-manual --disable-docs
    make -j"$JOBS"
    stage_install
}
