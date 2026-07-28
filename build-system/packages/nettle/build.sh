# nettle —— 加密库，gnutls 依赖
PKG_NAME="nettle"
PKG_VERSION="3.10"
PKG_SRC_URL="https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz"
PKG_SRC_SHA256="b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c"
PKG_SRC_DIR="nettle-3.10"

pkg_build() {
    # --disable-assembler：Termux 环境缺少 m4/as 汇编器，禁用汇编避免探测失败
    gnu_configure \
        --disable-assembler \
        --disable-documentation \
        --disable-openssl
    make -j"$JOBS"
    stage_install
}
