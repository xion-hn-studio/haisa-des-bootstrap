# gmp —— 任意精度算术库，nettle/gnutls 依赖
PKG_NAME="gmp"
PKG_VERSION="6.3.0"
PKG_SRC_URL="https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
PKG_SRC_SHA256="a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
PKG_SRC_DIR="gmp-6.3.0"

pkg_build() {
    gnu_configure --disable-assembly
    make -j"$JOBS"
    stage_install
}
