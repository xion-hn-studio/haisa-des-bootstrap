# nettle —— 加密库，gnutls 依赖
PKG_NAME="nettle"
PKG_VERSION="3.10"
PKG_SRC_URL="https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz"
PKG_SRC_SHA256="b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c"
PKG_SRC_DIR="nettle-3.10"

pkg_build() {
    # 指定 GMP 路径（来自 staging）：nettle 的 libhogweed（公钥算法）依赖 GMP，
    # configure 找不到 GMP 会输出 "Support for public key algorithms will be
    # unavailable" 并跳过 libhogweed.so 构建，导致下游 libgnutls 链接报
    # "unable to find library -lhogweed"。
    export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
    # --disable-assembler：Termux 环境缺少 m4/as 汇编器，禁用汇编避免探测失败
    gnu_configure \
        --disable-assembler \
        --disable-documentation \
        --disable-openssl
    make -j"$JOBS"
    stage_install
}
