# toybox —— 基础命令集（0BSD 许可证，商业友好；安装产生大量符号链接，顺带验证 SYMLINKS 机制）
PKG_NAME="toybox"
PKG_VERSION="0.8.12"
PKG_SRC_URL="https://codeload.github.com/landley/toybox/tar.gz/refs/tags/0.8.12"
PKG_SRC_SHA256="3c529d93923dde67d048e7bcbd5d1bc0dd1ad09362269e2415f5f2eaab349b5b"
PKG_SRC_DIR="toybox-0.8.12"

pkg_build() {
    # toybox 是 Android 原生工具集，NDK 交叉编译基本零适配
    # 注：defconfig 在 proot 环境下偶发瞬时失败（proot 已知怪癖），重试一次兜底
    make defconfig || { sleep 1; make defconfig; }
    # bionic 无 libcrypt，且 App 沙箱内这些命令无意义（与 Android 官方 toybox 配置一致）；
    # ICONV: demo 不需要，且本机冒烟时会被 Termux 环境的 libiconv 探测污染
    for opt in SU LOGIN PASSWD ICONV; do
        sed -i "s/^CONFIG_${opt}=y/# CONFIG_${opt} is not set/" .config
    done
    # 显式启用 defconfig 未默认启用但用户常用的命令
    # toybox defconfig 不会启用全部命令，awk/tr 等需要手动开启
    for opt in AWK TR; do
        sed -i "s/^# CONFIG_${opt} is not set/CONFIG_${opt}=y/" .config
    done
    # 禁用 GETCONF：getconf.c 包含 <libintl.h>（国际化），
    # NDK 无此头文件（Termux 由 libandroid-support 提供）。
    # Android 自带 getconf，禁用无影响。
    sed -i "s/^CONFIG_GETCONF=y/# CONFIG_GETCONF is not set/" .config
    make -j"$JOBS" CC="$CC" STRIP="$STRIP"

    # toybox 的 make install 会运行 ./toybox --install 创建命令符号链接，
    # 但交叉编译产物是 aarch64 二进制，在 x86_64 CI runner 上无法执行
    # （Exec format error），符号链接静默缺失。设备上 wc/head/cat 等全部
    # command not found。改用手动安装：复制二进制 + 从 .config 提取启用的
    # 命令列表，逐个创建符号链接。
    local bindir="$PKG_STAGE$PREFIX/bin"
    mkdir -p "$bindir"
    install -m 755 toybox "$bindir/toybox"

    # 从 .config 提取启用的命令：CONFIG_<CMD>=y → 命令名（小写）
    # toybox 的命令名是 CONFIG 名转小写，如 CONFIG_WC → wc, CONFIG_HEAD → head
    local cmd_count=0
    while IFS='=' read -r key val; do
        [ "$val" = "y" ] || continue
        case "$key" in
            CONFIG_*)
                # 去掉 CONFIG_ 前缀，转小写得命令名
                local cmd=$(echo "${key#CONFIG_}" | tr '[:upper:]' '[:lower:]')
                # 跳过非命令配置项（如 CONFIG_TOYBOX、CONFIG_TOYBOX_FORK 等）
                case "$cmd" in
                    toybox*|host*) continue ;;
                esac
                ln -sf toybox "$bindir/$cmd"
                cmd_count=$((cmd_count + 1))
                ;;
        esac
    done < .config
    log "  toybox: 手动创建 $cmd_count 个命令符号链接"

    verify_commands
}

# 校验关键命令符号链接存在，CI 阶段暴露安装问题
verify_commands() {
    local bindir="$PKG_STAGE$PREFIX/bin"
    # 用户最常用的命令——任一缺失说明安装流程有问题
    local required="wc head cat grep sed awk ls cp mv rm mkdir rmdir touch sort uniq tr cut date du df ps kill sleep echo printf pwd env true false"
    local missing=""
    for cmd in $required; do
        [ -e "$bindir/$cmd" ] || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        die "toybox 命令符号链接缺失:$missing——设备上会 command not found"
    fi
    log "  命令校验通过：关键命令符号链接均存在"
}
