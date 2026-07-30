# dpkg —— Debian 包管理后端，apt 调用它实际安装/卸载 .deb
#
# 源码用 Debian 发行 tarball（非 salsa git archive）：
#   - Debian tarball 已 autoreconf，不需要 ./autogen
#   - 1.22.20 在 Debian pool 已移除，升级到 1.22.22
#
# 关键补丁:
#   - patches/0001-skip-root-check.patch: 跳过 uid==0 检查
#     Android app 进程是非 root uid，dpkg 默认检查会导致
#     "requested operation requires superuser privilege"
#   - data/ostable: 添加 linux-android -> linux 映射（sed 内联）
#   - data/tupletable: 添加 aarch64-linux-android -> arm64 映射（sed 内联）
#
# 允许 Perl：不传 ac_cv_path_PERL=no，configure 自动探测
#   （Termux/CI 环境 pkg install perl 后可用；无 Perl 时跳过 manpage 生成）
#
# 禁用共享库：libdpkg 不支持共享库，必须 --disable-shared --enable-static
PKG_NAME="dpkg"
PKG_VERSION="1.22.22"
PKG_SRC_URL="https://deb.debian.org/debian/pool/main/d/dpkg/dpkg_1.22.22.tar.xz"
PKG_SRC_SHA256="d5ea9f132deec8030b50ab2a02ade2b49f0c7a195805a302c8301156fe833a57"
PKG_SRC_DIR="dpkg-1.22.22"

pkg_prepare_src() {
    extract_pkg "$PKG_NAME" "$PKG_SRC_URL" "$PKG_SRC_DIR"
    local src="$SRC_DIR/$PKG_SRC_DIR"

    # 应用 Android 适配 patch
    # --forward: 跳过已应用的 patch（幂等）
    # --no-backup-if-mismatch: 不留 .orig 文件
    local patch_dir="$BS_ROOT/packages/dpkg/patches"
    local p
    for p in "$patch_dir"/*.patch; do
        [ -f "$p" ] || continue
        log "dpkg: 应用 patch $(basename "$p")"
        patch -d "$src" -p1 --forward --no-backup-if-mismatch < "$p" || \
            warn "dpkg: patch $(basename "$p") 应用失败或已应用（忽略）"
    done

    # ostable: 添加 linux-android 条目
    # 格式: <Debian名>\t<GNU名>\t<正则>
    # GNU triple aarch64-linux-android 的 OS 部分是 "linux-android"
    # 正则必须精确匹配 "linux-android"（configure 用 $ 锚尾，"linux" 匹配不到）
    # Debian 名 "base-bionic-linux" = abi(base)+libc(bionic)+kernel(linux)
    # gnutriplet_to_debtuple 把 $os split(/-/,3) → ("base","bionic","linux")
    # 再拼 cpu("arm64") → tuple "base-bionic-linux-arm64"
    if ! grep -q '^base-bionic-linux' "$src/data/ostable" 2>/dev/null; then
        printf 'base-bionic-linux\t\tlinux-android\t\tlinux-android\n' >> "$src/data/ostable"
        log "dpkg: ostable 添加 base-bionic-linux 条目"
    fi

    # tupletable: 把 Debian tuple 映射到 Debian arch name
    # 我们的 .deb 用 Architecture: aarch64（Termux 惯例），所以映射到 aarch64
    if ! grep -q '^base-bionic-linux-arm64' "$src/data/tupletable" 2>/dev/null; then
        printf 'base-bionic-linux-arm64\t\taarch64\n' >> "$src/data/tupletable"
        log "dpkg: tupletable 添加 base-bionic-linux-arm64 → aarch64 映射"
    fi
}

pkg_build() {
    # dpkg 的 libdpkg 不支持共享库，必须 --disable-shared --enable-static
    # gnu_configure 默认 --disable-static --enable-shared，不能直接用，显式写 configure
    #
    # libmd 路径：dpkg configure AC_CHECK_LIB(md, MD5Init) 探测 BSD MD5 函数，
    # Android bionic 不导出，必须显式指向 staging 里的 libmd 头文件和库。
    export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
    # AC_CHECK_LIB 默认 -lmd + LIBS，绕过交叉链接器对 staging 路径不可见的问题
    export LIBS="-lmd"
    ./configure \
        --host="$TARGET_TRIPLE" \
        --prefix="$PREFIX" \
        --disable-shared --enable-static \
        --disable-dselect \
        --disable-start-stop-daemon \
        --disable-install-info \
        --disable-update-alternatives \
        --without-selinux \
        --with-admindir="$PREFIX/var/lib/dpkg" \
        --with-devlibdir="$PREFIX/lib"
    make -j"$JOBS"
    stage_install

    # 创建 dpkg 管理目录骨架（apt 运行时需要）
    local admindir="$PKG_STAGE$PREFIX/var/lib/dpkg"
    mkdir -p "$admindir"/{alternatives,info,parts,triggers,updates}
    touch "$admindir/status" "$admindir/available"
}
