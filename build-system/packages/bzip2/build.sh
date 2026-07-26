# bzip2 —— 块排序压缩库（Python _bz2 模块依赖）
PKG_NAME="bzip2"
PKG_VERSION="1.0.8"
PKG_SRC_URL="https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"
PKG_SRC_SHA256="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
PKG_SRC_DIR="bzip2-1.0.8"

pkg_build() {
    # bzip2 无 autoconf，用裸 Makefile；需手动构建共享库
    # 1) 共享库（Makefile-libbz2_so 产出 libbz2.so.1.0.8）
    make -f Makefile-libbz2_so CC="$CC" CFLAGS="$CFLAGS" -j"$JOBS"
    # 2) 静态库 + 命令行工具
    #    bzip2 Makefile 的默认 all 目标含 test：会执行 ./bzip2（aarch64 交叉产物），
    #    在 x86_64 宿主上触发 Exec format error。显式列出目标跳过 test。
    make CC="$CC" CFLAGS="$CFLAGS" -j"$JOBS" libbz2.a bzip2 bzip2recover
    # 安装静态库 + 头文件 + 工具
    make install PREFIX="$PKG_STAGE$PREFIX"
    # 手动安装共享库 + soname 符号链接（make install 不装 .so）
    # bzip2 1.0.8 的 soname 是 libbz2.so.1.0（Makefile-libbz2_so 用
    # -Wl,-soname,libbz2.so.1.0 链接），实际文件名是 libbz2.so.1.0.8。
    # 链接 _bz2.so 时 NEEDED 记录的是 soname（libbz2.so.1.0），必须建该名
    # 的符号链接，否则设备上 dlopen _bz2.so 报 "libbz2.so.1.0 not found"。
    local libdir="$PKG_STAGE$PREFIX/lib"
    cp -f libbz2.so.1.0.8 "$libdir/"
    ln -sf libbz2.so.1.0.8 "$libdir/libbz2.so.1.0"
    ln -sf libbz2.so.1.0.8 "$libdir/libbz2.so.1"
    ln -sf libbz2.so.1.0.8 "$libdir/libbz2.so"
}
