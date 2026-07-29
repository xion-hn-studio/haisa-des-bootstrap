# libgpg-error —— GnuPG 错误码库，libgcrypt 依赖
PKG_NAME="libgpg-error"
PKG_VERSION="1.51"
PKG_SRC_URL="https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2"
PKG_SRC_SHA256="be0f1b2db6b93eed55369cdf79f19f72750c8c7c39fc20b577e724545427e6b2"
PKG_SRC_DIR="libgpg-error-1.51"

pkg_prepare_src() {
    extract_pkg "$PKG_NAME" "$PKG_SRC_URL" "$PKG_SRC_DIR"
    local src="$SRC_DIR/$PKG_SRC_DIR"

    # 交叉编译时 configure 无法运行 gen-lock-obj.sh 检测 pthread_mutex_t 布局，
    # mkheader 会回退到 syscfg/lock-obj-pub.<host_os>.h。
    # config.sub 把 aarch64-linux-android 规范化为 aarch64-unknown-linux-android，
    # mkheader 提取 OS 部分 "linux-android"，查找 syscfg/lock-obj-pub.linux-android.h。
    # 上游源码不提供此文件 → 手动创建（复用 glibc aarch64 布局，_priv[48] 容量 ≥
    # bionic aarch64 pthread_mutex_t 的 40 字节，多出 8 字节为填充，安全）。
    local syscfg="$src/src/syscfg"
    local src_lock="$syscfg/lock-obj-pub.aarch64-unknown-linux-gnu.h"
    local dst_lock="$syscfg/lock-obj-pub.linux-android.h"
    if [ -f "$src_lock" ] && [ ! -f "$dst_lock" ]; then
        cp "$src_lock" "$dst_lock"
        log "libgpg-error: 创建 syscfg/lock-obj-pub.linux-android.h（复用 glibc aarch64 布局）"
    fi
}

pkg_build() {
    # CFLAGS 加 -Dpthread_cancel=0：Android bionic 无 pthread_cancel 符号，
    # src/posix-lock.c 用 use_pthread_p() 检测此符号存在性决定锁实现。
    # 定义为 0 让检测返回假，改用自旋锁实现，避免链接时缺符号。
    export CFLAGS="$CFLAGS -Dpthread_cancel=0"

    gnu_configure \
        --disable-nls \
        --disable-tests \
        --disable-doc
    make -j"$JOBS"
    stage_install

    # 上游安装的 bin/gpg-error-config 是 perl 脚本，shebang 指向安装时
    # 的 perl（如 /data/data/com.termux/files/usr/bin/perl 或 CI host 的 perl）。
    # 交叉编译下游包（libgcrypt）configure 要执行此脚本取 CFLAGS/LIBS，
    # 但 perl shebang 在执行环境可能不存在 → "No such file or directory"。
    # 用 host 可执行的 POSIX sh wrapper 替换：写死 $STAGE_DIR$PREFIX 绝对路径
    # （merge_stage 后下游从 $STAGE_DIR$PREFIX/bin/ 调用，路径有效）。
    # 不依赖 perl，跨 host（CI runner、Termux、其他设备）一致可执行。
    local bindir="$PKG_STAGE$PREFIX/bin"
    local stage_prefix="$STAGE_DIR$PREFIX"
    cat > "$bindir/gpg-error-config" <<EOF
#!/bin/sh
# haisa-des 交叉编译 wrapper：替代上游 perl 版 gpg-error-config。
case "\$1" in
    --version) echo "$PKG_VERSION" ;;
    --cflags)  echo "-I$stage_prefix/include" ;;
    --libs)    echo "-L$stage_prefix/lib -lgpg-error" ;;
    --prefix)  echo "$stage_prefix" ;;
    --host)    echo "aarch64-unknown-linux-android" ;;
    *)         echo "-I$stage_prefix/include -L$stage_prefix/lib -lgpg-error" ;;
esac
EOF
    chmod 755 "$bindir/gpg-error-config"
    log "libgpg-error: 替换 gpg-error-config 为 sh wrapper（绕过 perl shebang）"
}
