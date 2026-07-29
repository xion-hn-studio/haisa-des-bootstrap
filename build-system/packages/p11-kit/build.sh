# p11-kit —— PKCS#11 模块加载器，gnutls 依赖
PKG_NAME="p11-kit"
PKG_VERSION="0.25.5"
PKG_SRC_URL="https://github.com/p11-glue/p11-kit/releases/download/0.25.5/p11-kit-0.25.5.tar.xz"
PKG_SRC_SHA256="04d0a86450cdb1be018f26af6699857171a188ac6d5b8c90786a60854e1198e5"
PKG_SRC_DIR="p11-kit-0.25.5"

pkg_build() {
    # 指定 libtasn1 路径（来自 staging）
    export LIBTASN1_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export LIBTASN1_LIBS="-L$STAGE_DIR$PREFIX/lib -ltasn1"
    # 指定 libffi 路径：p11-kit/virtual.c:74 用 #include "ffi.h"，
    # 需 -I 显式指定 staging include 路径（pkg-config 检测能找到但
    # CFLAGS 没传给 make，virtual.c 编译时找不到头文件）
    export FFI_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export FFI_LIBS="-L$STAGE_DIR$PREFIX/lib -lffi"
    # 备用：直接加到 CFLAGS/LDFLAGS 兜底（p11-kit 0.25 configure 不一定用 FFI_CFLAGS）
    export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"

    gnu_configure \
        --disable-trust-module \
        --disable-doc \
        --without-systemd \
        --without-bash-completion
    make -j"$JOBS"
    stage_install
}
