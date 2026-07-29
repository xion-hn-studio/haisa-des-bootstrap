# libidn2 —— IDN2008 库，gnutls 依赖
PKG_NAME="libidn2"
PKG_VERSION="2.3.7"
PKG_SRC_URL="https://ftp.gnu.org/gnu/libidn/libidn2-2.3.7.tar.gz"
PKG_SRC_SHA256="4c21a791b610b9519b9d0e12b8097bf2f359b12f8dd92647611a929e6bfd7d64"
PKG_SRC_DIR="libidn2-2.3.7"

pkg_build() {
    # 指定 libunistring 路径（来自 staging）
    # gnulib 的 AM_LIB_UNISTRING 检测在交叉编译时无法运行 test program，
    # 即使设了 LIBUNISTRING(LIBS/CFLAGS) 也会失败（"Libunistring was not found"）。
    # 用 --with-included-unistring 直接用 libidn2 源码自带的 libunistring 副本，
    # 避免依赖检测，编译时静态链接进 libidn2.so（不产生独立 libunistring.so 冗余）。
    export CPPFLAGS="-I$STAGE_DIR$PREFIX/include"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"

    gnu_configure \
        --with-included-unistring \
        --disable-doc \
        --disable-tests \
        --disable-rpath
    make -j"$JOBS"
    stage_install
}
