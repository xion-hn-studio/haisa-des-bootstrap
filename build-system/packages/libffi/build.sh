# libffi —— 外部函数接口库（Python _ctypes 模块依赖）
PKG_NAME="libffi"
PKG_VERSION="3.4.6"
PKG_SRC_URL="https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz"
PKG_SRC_SHA256="b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"
PKG_SRC_DIR="libffi-3.4.6"

pkg_build() {
    gnu_configure --disable-builddir
    make -j"$JOBS"
    stage_install
    # .la 文件 libdir 修正由通用 fix_la_paths（build.sh 调用）统一处理
}
