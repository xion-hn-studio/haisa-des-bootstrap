# sqlite —— 嵌入式 SQL 数据库（Python _sqlite3 模块依赖）
PKG_NAME="sqlite"
PKG_VERSION="3.46.1"
PKG_SRC_URL="https://www.sqlite.org/2024/sqlite-autoconf-3460100.tar.gz"
PKG_SRC_SHA256="67d3fe6d268e6eaddcae3727fce58fcc8e9c53869bdd07a0c61e38ddf2965071"
PKG_SRC_DIR="sqlite-autoconf-3460100"

pkg_build() {
    gnu_configure --disable-static --enable-shared
    make -j"$JOBS"
    stage_install
}
