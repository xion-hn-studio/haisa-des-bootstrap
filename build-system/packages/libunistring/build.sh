# libunistring —— Unicode 字符串库，libidn2/gnutls 依赖
PKG_NAME="libunistring"
PKG_VERSION="1.3"
PKG_SRC_URL="https://ftp.gnu.org/gnu/libunistring/libunistring-1.3.tar.xz"
PKG_SRC_SHA256="f245786c831d25150f3dfb4317cda1acc5e3f79a5da4ad073ddca58886569527"
PKG_SRC_DIR="libunistring-1.3"

pkg_build() {
    gnu_configure --disable-doc
    make -j"$JOBS"
    stage_install
}
