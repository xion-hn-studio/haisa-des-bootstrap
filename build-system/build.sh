#!/usr/bin/env bash
# HaisaDes 构建系统入口
# 用法:
#   ./build.sh list                列出全部包及依赖
#   ./build.sh build <包...|all>   构建（含依赖），产物进 staging
#   ./build.sh bootstrap           在 build all 之后打出 dist/bootstrap-<abi>[-test].zip
#   ./build.sh repo                生成 apt 仓库元数据并签名（make-apt-repo + make-keyring sign）
#   ./build.sh clean [包...]       清理
# 环境变量: TOOLCHAIN=ndk|termux-local（默认 ndk）  VARIANT=prod|test（默认 prod）  JOBS=N
set -euo pipefail

BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$BS_ROOT/config.sh"
# shellcheck source=lib/common.sh
source "$BS_ROOT/lib/common.sh"

# 包名列表（构建顺序即依赖顺序）
# M3.1 扩展：SDL2 系列 7 包（libpng/libjpeg-turbo/freetype/SDL2/image/mixer/ttf）
# 用于支持设备端 pip 安装 pygame 等图形库 wheel（无需 gcc）
# M3.2 扩展：apt 命令行（包管理器 CLI，Debian apt 风格）
# M3.3 扩展：pip wrapper 已合并到 python 包内（python 包 build 时一并安装 wrapper + pip.real）
# M4 扩展：真 apt 2.8.1 + dpkg + 14 个依赖库（liblz4/zstd/xxhash/libiconv/
#          libgpg-error/libgcrypt/gmp/nettle/libtasn1/p11-kit/libunistring/libidn2/libgnutls/libmd）
ALL_PACKAGES="zlib ncurses bash openssl ca-certificates curl toybox \
              libffi sqlite bzip2 xz expat readline \
              liblz4 zstd xxhash libiconv \
              libgpg-error libgcrypt \
              gmp nettle libtasn1 p11-kit libunistring libidn2 libgnutls \
              libpng libjpeg-turbo freetype sdl2 sdl2_image sdl2_mixer sdl2_ttf \
              python libmd dpkg apt"

# 内置包：打进 bootstrap.zip 的包（不打单独 .deb，也不进 Packages 索引）
# M4 后 apt 改为真 apt 编译，打 .deb；bootstrap.zip 只含最小运行时（手动指定）
# 当前保留空列表：所有包都打 .deb，bootstrap.zip 仍含全部（兼容现有 App 端）
BUILTIN_PACKAGES=""

pkg_deps() {
    case "$1" in
        zlib)            echo "" ;;
        ncurses)         echo "" ;;
        bash)            echo "ncurses" ;;
        openssl)        echo "zlib" ;;
        ca-certificates) echo "" ;;
        curl)            echo "zlib openssl ca-certificates" ;;
        toybox)          echo "" ;;
        libffi)          echo "" ;;
        sqlite)          echo "" ;;
        bzip2)           echo "" ;;
        xz)              echo "" ;;
        expat)           echo "" ;;
        readline)        echo "ncurses" ;;
        # python 拓扑依赖：bootstrap 已含的运行时库（用户 apt install python 时按需装缺失的）
        python)          echo "zlib openssl ncurses readline libffi sqlite bzip2 xz expat" ;;
        # ---- M3.1 SDL2 系列 ----
        libpng)          echo "zlib" ;;
        libjpeg-turbo)   echo "" ;;
        freetype)        echo "zlib libpng bzip2" ;;
        sdl2)            echo "" ;;
        sdl2_image)      echo "sdl2 libpng libjpeg-turbo" ;;
        sdl2_mixer)      echo "sdl2" ;;
        sdl2_ttf)        echo "sdl2 freetype" ;;
        # ---- M4 真 apt 依赖链 ----
        # 层级 0：无依赖
        liblz4)          echo "" ;;
        zstd)            echo "" ;;
        xxhash)          echo "" ;;
        libiconv)        echo "" ;;
        # 层级 1：libgcrypt 链
        libgpg-error)    echo "" ;;
        libgcrypt)       echo "libgpg-error" ;;
        # 层级 2：libgnutls 链
        gmp)             echo "" ;;
        nettle)          echo "gmp" ;;
        libtasn1)        echo "" ;;
        p11-kit)         echo "libtasn1" ;;
        libunistring)    echo "" ;;
        libidn2)         echo "libunistring" ;;
        libgnutls)       echo "gmp nettle libtasn1 p11-kit libunistring libidn2" ;;
        # libmd：BSD 风格 MD5/SHA 摘要库，dpkg 硬依赖（bionic 不导出 MD5Init）
        libmd)           echo "" ;;
        # dpkg：静态库；依赖 libmd（BSD 风格 MD5Init/MD5Update/MD5Final）
        dpkg)            echo "libmd" ;;
        # apt：真 Debian apt 2.8.1，依赖 dpkg + TLS/压缩库
        apt)             echo "dpkg liblz4 zstd xxhash libiconv libgcrypt libgnutls" ;;
        *) die "未知包: $1" ;;
    esac
}

load_pkg() {
    local name="$1"
    local f="$BS_ROOT/packages/$name/build.sh"
    [ -f "$f" ] || die "缺少包定义: packages/$name/build.sh"
    PKG_NAME="" PKG_VERSION="" PKG_SRC_URL="" PKG_SRC_SHA256="" PKG_SRC_DIR=""
    unset -f pkg_build pkg_prepare_src 2>/dev/null || true
    PKG_STAGE="$PKG_STAGE_ROOT/$name"
    # shellcheck source=/dev/null
    source "$f"
    [ -n "$PKG_NAME" ] && [ -n "$PKG_SRC_URL" ] || die "packages/$name/build.sh 元数据不完整"
    declare -F pkg_build >/dev/null || die "packages/$name/build.sh 缺少 pkg_build()"
}

build_one() {
    local name="$1"
    load_pkg "$name"
    if [ -f "$PKG_STAGE/.done" ]; then
        log "$name-$PKG_VERSION: 已构建（$PKG_STAGE/.done），跳过。clean 后可重建"
        return 0
    fi
    log "===== 构建 $name-$PKG_VERSION ====="
    rm -rf "$PKG_STAGE"; mkdir -p "$PKG_STAGE"
    fetch_pkg "$name" "$PKG_SRC_URL" "$PKG_SRC_SHA256"
    if declare -F pkg_prepare_src >/dev/null; then
        pkg_prepare_src   # 纯数据包自建源码目录
    else
        extract_pkg "$name" "$PKG_SRC_URL" "$PKG_SRC_DIR"
    fi
    ( cd "$SRC_DIR/$PKG_SRC_DIR" && pkg_build )
    # 修复 .la 文件 libdir（交叉编译时 libtool 记录设备路径，CI 主机找不到）
    fix_la_paths
    merge_stage "$name"
    # 打 .deb（BUILTIN_PACKAGES 不打，打进 bootstrap.zip）
    case " $BUILTIN_PACKAGES " in
        *" $name "*) log "$name: 内置包，不打 .deb（进 bootstrap.zip）" ;;
        *)
            local deps_csv
            deps_csv=$(pkg_deps "$name" | tr ' ' ',' | sed 's/,$//')
            make_deb "$deps_csv" "${PKG_DESC:-}"
            ;;
    esac
    touch "$PKG_STAGE/.done"
    log "===== $name-$PKG_VERSION 完成 ====="
}

# 拓扑展开（依赖先于本体；手工顺序，包少无需泛化）
expand_with_deps() {
    local out="" p d
    for p in "$@"; do
        for d in $(pkg_deps "$p"); do
            case " $out " in *" $d "*) ;; *) out="$out $d" ;; esac
        done
        case " $out " in *" $p "*) ;; *) out="$out $p" ;; esac
    done
    echo $out
}

cmd="${1:-}"; shift || true
case "$cmd" in
    list)
        for p in $ALL_PACKAGES; do
            load_pkg "$p"
            printf "%-16s %-12s deps: %s\n" "$p" "$PKG_VERSION" "$(pkg_deps "$p")"
        done
        ;;
    build)
        # 工具链在真正编译前才加载（list/clean 不需要 NDK）
        case "$TOOLCHAIN" in
            ndk)          _tc="ndk-r29.sh" ;;
            termux-local) _tc="termux-local.sh" ;;
            *) die "未知 TOOLCHAIN=$TOOLCHAIN（可选: ndk, termux-local）" ;;
        esac
        # shellcheck source=/dev/null
        source "$BS_ROOT/toolchains/$_tc"
        targets="${*:-all}"
        [ "$targets" = "all" ] && set -- $ALL_PACKAGES || set -- $targets
        order=$(expand_with_deps "$@")
        log "构建顺序: $order  (VARIANT=$VARIANT PREFIX=$PREFIX JOBS=$JOBS)"
        for p in $order; do build_one "$p"; done
        log "全部完成。staging: $STAGE_DIR"
        ;;
    bootstrap)
        "$BS_ROOT/make-bootstrap.sh"
        ;;
    repo)
        # 生成 Debian 仓库元数据（Release/Packages/Packages.gz）并签名
        # CI 用法：
        #   printf '%s' "$HAISADES_GPG_PRIVATE_KEY" | ./make-keyring.sh import-private
        #   ./build.sh repo
        # 本地用法（需先 ./make-keyring.sh init .gpg）：
        #   ./build.sh repo
        "$BS_ROOT/make-apt-repo.sh"
        rel="$DIST_DIR/apt-repo/dists/stable/Release"
        if [ ! -f "$rel" ]; then
            die "Release 文件未生成: $rel（先确保 make-apt-repo.sh 成功）"
        fi
        if [ -n "${HAISADES_GPG_PRIVATE_KEY:-}" ] || [ -d "$BS_ROOT/.gpg" ] || [ -d "$BS_ROOT/.ci-keyring" ]; then
            # CI 模式：从 Secret 注入私钥到临时 keyring；本地模式：直接用 .gpg/
            if [ -n "${HAISADES_GPG_PRIVATE_KEY:-}" ] && [ ! -d "$BS_ROOT/.ci-keyring" ]; then
                printf '%s' "$HAISADES_GPG_PRIVATE_KEY" | "$BS_ROOT/make-keyring.sh" import-private
            fi
            # 本地模式优先 .gpg/（已有密钥），否则用 CI 注入的 .ci-keyring/
            if [ -d "$BS_ROOT/.gpg" ]; then
                GNUPGHOME="$BS_ROOT/.gpg" "$BS_ROOT/make-keyring.sh" sign "$rel"
            else
                "$BS_ROOT/make-keyring.sh" sign "$rel"
            fi
            log "仓库已签名: $DIST_DIR/apt-repo/"
        else
            warn "未配置 GPG 密钥（HAISADES_GPG_PRIVATE_KEY 未设置且无 .gpg/）"
            warn "  仅生成未签名 Release。设备端需在 sources.list 加 [trusted=yes] 临时降级。"
            warn "  生产部署：本地 ./make-keyring.sh init .gpg 后把公钥提交到仓库"
        fi
        ;;
    clean)
        if [ $# -eq 0 ]; then rm -rf "$WORK_DIR" "$DIST_DIR"; log "已清理 $VARIANT 全部产物";
        else for p in "$@"; do rm -rf "$PKG_STAGE_ROOT/$p" "$SRC_DIR"; log "已清理 $p（源码缓存保留）"; done; fi
        ;;
    *)
        sed -n '2,9p' "$0"; exit 1 ;;
esac
