# libgpg-error —— GnuPG 错误码库，libgcrypt 依赖
PKG_NAME="libgpg-error"
PKG_VERSION="1.51"
PKG_SRC_URL="https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2"
PKG_SRC_SHA256="be0f1b2db6b93eed55369cdf79f19f72750c8c7c39fc20b577e724545427e6b2"
PKG_SRC_DIR="libgpg-error-1.51"

pkg_build() {
    # CFLAGS 加 -Dpthread_cancel=0：Android bionic 无 pthread_cancel 符号，
    # src/posix-lock.c 用 use_pthread_p() 检测此符号存在性决定锁实现。
    # 定义为 0 让检测返回假，改用自旋锁实现，避免链接时缺符号。
    export CFLAGS="$CFLAGS -Dpthread_cancel=0"

    gnu_configure \
        --disable-nls \
        --disable-tests \
        --disable-doc
    make -j"$JOBS"
    stage_install
}
