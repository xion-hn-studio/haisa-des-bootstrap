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
    # p11-kit 头文件装在 $PREFIX/include/p11-kit-1/p11-kit/，
    # libgnutls 用 #include <p11-kit/pkcs11.h>，需 -I 指向 p11-kit-1 目录。
    # pkg-config 返回的 cflags 是设备路径（$PREFIX），CI 时需指向 staging。
    export P11_KIT_CFLAGS="-I$STAGE_DIR$PREFIX/include/p11-kit-1"
    export P11_KIT_LIBS="-L$STAGE_DIR$PREFIX/lib -lp11-kit"
    export LIBUNISTRING_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export LIBUNISTRING_LIBS="-L$STAGE_DIR$PREFIX/lib -lunistring"

    # AC_CHECK_FUNCS 在交叉编译时无法运行 test program 检测符号存在性，
    # libgnutls configure 会因 "nettle_rsa_sec_decrypt not found" 失败。
    # 用 cache 变量 ac_cv_func_<func>=yes 跳过运行时检测。
    # nettle 3.10 确实有这些符号（rsa.h:97 宏重命名 rsa_* → nettle_rsa_*）。
    export ac_cv_func_nettle_rsa_sec_decrypt=yes
    export ac_cv_func_nettle_rsa_oaep_sha256_encrypt=yes
    # AC_CHECK_LIB(hogweed, nettle_get_secp_192r1) 同问题
    export ac_cv_lib_hogweed_nettle_get_secp_192r1=yes

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
