# libgcrypt —— 加密库，apt TLS 链依赖
PKG_NAME="libgcrypt"
PKG_VERSION="1.11.0"
PKG_SRC_URL="https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2"
PKG_SRC_SHA256="09120c9867ce7f2081d6aaa1775386b98c2f2f246135761aae47d81f58685b9c"
PKG_SRC_DIR="libgcrypt-1.11.0"

pkg_build() {
    # PKG_CONFIG_PATH 兼容未设置环境变量：
    # ${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH} 仅在 PKG_CONFIG_PATH 非空时展开为 :$PKG_CONFIG_PATH，
    # 避免空值产生尾随冒号导致 pkg-config 误搜索当前目录。
    export PKG_CONFIG_PATH="$STAGE_DIR$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    # libgpg-error 1.51 安装的 gpg-error-config 是 perl 脚本，
    # 交叉编译时 shebang 指向 host perl 无法执行（CI 报 "No such file or directory"）。
    # 直接导出 CFLAGS/LIBS 绕过 gpg-error-config 调用（AM_PATH_GPG_ERROR 优先用环境变量）。
    export GPG_ERROR_CFLAGS="-I$STAGE_DIR$PREFIX/include"
    export GPG_ERROR_LIBS="-L$STAGE_DIR$PREFIX/lib -lgpg-error"

    # --with-libgpg-error-prefix 指向刚编译的 libgpg-error staging
    # --disable-asm：Android bionic 汇编兼容性问题
    gnu_configure \
        --with-libgpg-error-prefix="$STAGE_DIR$PREFIX" \
        --disable-nls \
        --disable-tests \
        --disable-doc \
        --disable-asm
    make -j"$JOBS"
    stage_install
}
