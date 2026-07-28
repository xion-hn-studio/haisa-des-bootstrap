# libtasn1 —— ASN.1 库，gnutls/p11-kit 依赖
PKG_NAME="libtasn1"
PKG_VERSION="4.20.0"
PKG_SRC_URL="https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz"
PKG_SRC_SHA256="92e0e3bd4c02d4aeee76036b2ddd83f0c732ba4cda5cb71d583272b23587a76c"
PKG_SRC_DIR="libtasn1-4.20.0"

pkg_build() {
    gnu_configure --disable-doc --disable-tests
    make -j"$JOBS"
    stage_install
}
