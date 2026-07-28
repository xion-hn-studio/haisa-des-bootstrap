# libidn2 —— IDN2008 库，gnutls 依赖
PKG_NAME="libidn2"
PKG_VERSION="2.3.7"
PKG_SRC_URL="https://ftp.gnu.org/gnu/libidn/libidn2-2.3.7.tar.gz"
PKG_SRC_SHA256="4c21a791b610b9519b9d0e12b8097bf2f359b12f8dd92647611a929e6bfd7d64"
PKG_SRC_DIR="libidn2-2.3.7"

pkg_build() {
    # 指定 libunistring 路径（来自 staging）
    export UNISTRING_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export UNISTRING_LIBS="-L$STAGE_DIR$PREFIX/lib -lunistring"

    gnu_configure \
        --disable-doc \
        --disable-tests \
        --disable-rpath
    make -j"$JOBS"
    stage_install
}
