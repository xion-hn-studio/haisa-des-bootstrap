# readline —— 行编辑库（Python readline 模块依赖，交互式 REPL 行编辑）
PKG_NAME="readline"
PKG_VERSION="8.2"
PKG_SRC_URL="https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz"
PKG_SRC_SHA256="3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a053331d7d1095007c35"
PKG_SRC_DIR="readline-8.2"

pkg_build() {
    # 依赖 ncurses（已在总 staging 中）：头文件 include/ncursesw，库 libncursesw + libncurses.so 兼容链接
    export CPPFLAGS="-I$STAGE_DIR$PREFIX/include -I$STAGE_DIR$PREFIX/include/ncursesw"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
    # 显式指定 termcap 库为 libncursesw——readline configure 在交叉编译下无法运行
    # 测试程序检测 termcap 库，会误判为"无 termcap"，导致 libreadline.so 不记录
    # 对 libncursesw 的 NEEDED 依赖。设备上 dlopen libreadline.so 时，其内部引用
    # 的 PC 符号（termcap pad character，由 libncursesw 提供）无法解析，报
    # "cannot locate symbol PC referenced by libreadline.so.8.2"。
    # bash_cv_termcap_lib 是 readline/bash 共用的 autoconf cache 变量，
    # 取值 libncursesw 让 configure 设 TERMCAP_LIB=-lncursesw。
    # 但 readline 8.2 的共享库链接实际用 SHLIB_LIBS（configure 时已替换为空），
    # 仅靠 cache 变量不够，必须在 make 时命令行覆盖 SHLIB_LIBS 才能生效。
    export bash_cv_termcap_lib=libncursesw
    gnu_configure --with-curses
    # SHLIB_LIBS 命令行覆盖：GNU make 命令行变量优先级高于 Makefile 赋值，
    # 强制 libreadline.so / libhistory.so 链接 -lncursesw，记录 NEEDED。
    make -j"$JOBS" SHLIB_LIBS="-lncursesw"
    stage_install
    verify_needed
}

# 校验 libreadline.so 的 NEEDED 含 libncursesw.so，确保运行时 PC 符号可解析。
verify_needed() {
    local so="$PKG_STAGE$PREFIX/lib/libreadline.so.8.2"
    [ -f "$so" ] || die "libreadline.so.8.2 未安装"
    local needed
    needed=$("$READELF" -d "$so" 2>/dev/null | sed -n 's/.*NEEDED.*\[\([^]]*\)\].*/\1/p')
    local found=0
    for lib in $needed; do
        case "$lib" in
            libncursesw.so*) found=1; break ;;
        esac
    done
    if [ "$found" -eq 0 ]; then
        warn "  libreadline.so.8.2 NEEDED: $(echo $needed | tr '\n' ' ')"
        die "libreadline.so 未记录对 libncursesw 的 NEEDED 依赖，设备上 import readline 会因 PC 符号无法解析而 dlopen 失败"
    fi
    log "  NEEDED 校验通过：libreadline.so.8.2 依赖 libncursesw.so"
}
