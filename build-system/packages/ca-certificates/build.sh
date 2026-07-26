# ca-certificates —— CA 根证书（curl/openssl 校验 HTTPS 用）
PKG_NAME="ca-certificates"
PKG_VERSION="2025-07-15"
PKG_SRC_URL="https://curl.se/ca/cacert-2025-07-15.pem"
PKG_SRC_SHA256="7430e90ee0cdca2d0f02b1ece46fbf255d5d0408111f009638e3b892d6ca089c"
PKG_SRC_DIR="ca-certificates-2025-07-15"

pkg_build() {
    # 纯数据包：无编译，直接布置到 $PREFIX/etc/ssl
    local dst="$PKG_STAGE$PREFIX/etc/ssl"
    mkdir -p "$dst/certs"
    cp "$CACHE_DIR/cacert-2025-07-15.pem" "$dst/certs/ca-certificates.crt"
    cp "$CACHE_DIR/cacert-2025-07-15.pem" "$dst/cert.pem"
    # 附带 MPL-2.0 许可证头已包含在 pem 文件注释中
}

# 纯数据包：无 tarball 可解，自建（空）源码目录占位
pkg_prepare_src() {
    mkdir -p "$SRC_DIR/$PKG_SRC_DIR"
}
