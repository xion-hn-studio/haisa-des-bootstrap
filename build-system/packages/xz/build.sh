# xz —— LZMA 压缩库 liblzma（Python _lzma 模块依赖）
PKG_NAME="xz"
PKG_VERSION="5.6.2"
PKG_SRC_URL="https://github.com/tukaani-project/xz/releases/download/v5.6.2/xz-5.6.2.tar.gz"
PKG_SRC_SHA256="8bfd20c0e1d86f0402f2497cfa71c6ab62d4cd35fd704276e3140bfb71414519"
PKG_SRC_DIR="xz-5.6.2"

pkg_build() {
    gnu_configure --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo
    make -j"$JOBS"
    stage_install
}
