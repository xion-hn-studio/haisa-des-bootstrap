# libgnutls —— TLS 库，apt HTTPS 依赖
PKG_NAME="libgnutls"
PKG_VERSION="3.8.9"
PKG_SRC_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.9.tar.xz"
PKG_SRC_SHA256="69e113d802d1670c4d5ac1b99040b1f2d5c7c05daec5003813c049b5184820ed"
PKG_SRC_DIR="gnutls-3.8.9"

pkg_build() {
    # 显式指定所有依赖的路径（来自 staging）
    export GMP_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export GMP_LIBS="-L$STAGE_DIR$PREFIX/lib -lgmp"
    export NETTLE_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export NETTLE_LIBS="-L$STAGE_DIR$PREFIX/lib -lnettle"
    export HOGWEED_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export HOGWEED_LIBS="-L$STAGE_DIR$PREFIX/lib -lhogweed"
    export LIBTASN1_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export LIBTASN1_LIBS="-L$STAGE_DIR$PREFIX/lib -ltasn1"
    export LIBIDN2_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export LIBIDN2_LIBS="-L$STAGE_DIR$PREFIX/lib -lidn2"
    export P11_KIT_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export P11_KIT_LIBS="-L$STAGE_DIR$PREFIX/lib -lp11-kit"
    export LIBUNISTRING_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export LIBUNISTRING_LIBS="-L$STAGE_DIR$PREFIX/lib -lunistring"

    # disable 大量子模块简化编译：tools/cxx/doc/tests/libdane/hardware-acceleration
    # --with-included-unistring: gnulib AM_LIB_UNISTRING 交叉编译时无法运行
    # test program 检测 u8_normalize，"Libunistring was not found"。
    # 用源码自带的 libunistring 副本静态链接，避免依赖检测。
    gnu_configure \
        --with-included-unistring \
        --disable-doc \
        --disable-tests \
        --disable-tools \
        --disable-cxx \
        --disable-maintainer-mode \
        --disable-libdane \
        --disable-hardware-acceleration
    make -j"$JOBS"
    stage_install
}
