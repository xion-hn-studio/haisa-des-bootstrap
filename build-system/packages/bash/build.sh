# bash —— 交互 shell（使用内置 readline，少一个依赖）
PKG_NAME="bash"
PKG_VERSION="5.2.37"
PKG_SRC_URL="https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
PKG_SRC_SHA256="9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"
PKG_SRC_DIR="bash-5.2.37"

pkg_build() {
    # 依赖 ncurses 的头文件与库（已在总 staging 中）
    # 我们的 ncurses 6.5 构建为 wide 版：头文件在 include/ncursesw，库名 libncursesw
    export CPPFLAGS="-I$STAGE_DIR$PREFIX/include -I$STAGE_DIR$PREFIX/include/ncursesw"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"

    # autoconf 交叉缓存变量（bionic/Linux 的已知事实值，避免 configure 尝试运行目标程序）
    gnu_configure \
        --without-bash-malloc \
        --with-curses \
        --disable-nls \
        bash_cv_dev_fd=standard \
        bash_cv_getcwd_malloc=yes \
        bash_cv_getenv_redef=yes \
        bash_cv_job_control_missing=present \
        bash_cv_sys_named_pipes=present \
        bash_cv_func_sigsetjmp=present \
        bash_cv_func_snprintf=yes \
        bash_cv_func_vsnprintf=yes \
        bash_cv_func_strtod=yes \
        bash_cv_printf_a_format=yes \
        bash_cv_termcap_lib=ncursesw \
        bash_cv_unusable_rtsigs=no \
        bash_cv_wcontinued_broken=no \
        bash_cv_dup2_broken=no \
        bash_cv_pgrp_pipe=yes \
        bash_cv_must_reinstall_sighandlers=no \
        ac_cv_func_setvbuf_reversed=no \
        ac_cv_header_libintl_h=no
    make -j"$JOBS"
    stage_install
}
