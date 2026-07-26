# ncurses —— bash 的终端库
PKG_NAME="ncurses"
PKG_VERSION="6.5"
PKG_SRC_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz"
PKG_SRC_SHA256="136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"
PKG_SRC_DIR="ncurses-6.5"

pkg_build() {
    # --with-build-cc: 交叉时仍需宿主编译器构建 tic 等工具
    gnu_configure \
        --with-build-cc="gcc" \
        --with-shared --without-debug --without-ada \
        --without-cxx-binding --without-tests --without-manpages \
        --with-default-terminfo-dir="$PREFIX/share/terminfo" \
        --disable-stripping
    make -j"$JOBS"
    stage_install

    # 裁剪 terminfo 数据库：只保留常用终端类型，控制 bootstrap 体积
    local ti="$PKG_STAGE$PREFIX/share/terminfo"
    if [ -d "$ti" ]; then
        for d in "$ti"/*/; do
            case "$(basename "$d")" in
                a|d|l|r|s|v|x) : ;;  # ansi/dumb/linux/rxvt/screen/vt100/xterm
                *) rm -rf "$d" ;;
            esac
        done
    fi
    # 为兼容 bash `--with-curses` / `lncurses` 等硬编码查找，创建兼容符号链接
    (cd "$PKG_STAGE$PREFIX/lib" && ln -sf libncursesw.so libncurses.so && ln -sf libncursesw.so libncurses.so.6) || true
}
