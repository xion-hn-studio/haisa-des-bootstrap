# libiconv —— 字符编码转换库，apt 依赖
# Android bionic 自带 iconv（系统库），但功能受限；Termux 用 GNU libiconv
# 注意：libiconv 会覆盖 bionic 的 iconv，可能导致字符处理变化（Termux 实际做法）
PKG_NAME="libiconv"
PKG_VERSION="1.18"
PKG_SRC_URL="https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.18.tar.gz"
PKG_SRC_SHA256="3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8"
PKG_SRC_DIR="libiconv-1.18"

pkg_build() {
    gnu_configure
    make -j"$JOBS"
    stage_install
}
