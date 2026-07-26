# expat —— XML 解析库（Python pyexpat 模块依赖）
PKG_NAME="expat"
PKG_VERSION="2.6.2"
PKG_SRC_URL="https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.bz2"
PKG_SRC_SHA256="9c7c1b5dcbc3c237c500a8fb1493e14d9582146dd9b42aa8d3ffb856a3b927e0"
PKG_SRC_DIR="expat-2.6.2"

pkg_build() {
    gnu_configure --without-examples --without-tests
    make -j"$JOBS"
    stage_install
}
