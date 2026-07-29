# HaisaDes 构建公共函数库（由 build.sh source）

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# fetch_pkg <name> <url> <sha256>
# 下载源码到 CACHE_DIR 并校验 sha256；幂等。
# url 支持 local://<相对路径> 形式：从 $BS_ROOT 下相对路径读取，
# 避免因外部下载不稳定把源码 vendor 进仓库（如 pygame release 无 tarball 时）。
fetch_pkg() {
    local name="$1" url="$2" sha="$3"
    local file="$CACHE_DIR/${url##*/}"
    mkdir -p "$CACHE_DIR"

    # local:// 从仓库内拷贝，跳过 curl
    if [[ "$url" == local://* ]]; then
        local rel="${url#local://}"
        local src="$BS_ROOT/$rel"
        [ -f "$src" ] || die "$name: 本地源码不存在: $src"
        # 缓存命中且校验通过则跳过拷贝
        if [ -f "$file" ] && [ -n "$sha" ] && echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1; then
            log "$name: 缓存命中 ${url##*/}"
            return 0
        fi
        log "$name: 从仓库内拷贝 $rel"
        cp -f "$src" "$file"
    else
        if [ -f "$file" ]; then
            if [ -n "$sha" ] && echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1; then
                log "$name: 缓存命中 ${url##*/}"
                return 0
            fi
            warn "$name: 缓存校验失败，重新下载"
            rm -f "$file"
        fi
        log "$name: 下载 $url"
        # --retry 5 --retry-delay 5：5 次重试 + 指数退避（5/10/20/40/80s ≈ 2.5 分钟）
        # 应对 savannah/sourceforge 等镜像临时 502/504 网关错误（实测可持续数分钟）
        # --retry-all-errors：对 HTTP 5xx 错误也重试（curl 默认只对连接错误重试）
        curl -fSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
            -o "$file" "$url" || die "$name 下载失败: $url"
    fi
    if [ -n "$sha" ]; then
        echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1 || die "$name sha256 校验失败"
    fi
}

# extract_pkg <name> <url> <srcdir_in_tar>
# 解压到临时目录后原子 rename，避免中断留下“看似完整”的残缺源码树。
extract_pkg() {
    local name="$1" url="$2" topdir="$3"
    local file="$CACHE_DIR/${url##*/}"
    local dest="$SRC_DIR/$topdir"
    local tmp="$SRC_DIR/.extracting-$topdir.$$"
    mkdir -p "$SRC_DIR"
    if [ -d "$dest" ]; then
        log "$name: 源码目录已存在，跳过解压"
        return 0
    fi
    log "$name: 解压 ${url##*/}"
    rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xf "$file" -C "$tmp" || { rm -rf "$tmp"; die "$name 解压失败"; }
    [ -d "$tmp/$topdir" ] || { rm -rf "$tmp"; die "$name tarball 顶层目录与 PKG_SRC_DIR($topdir) 不一致"; }
    mv "$tmp/$topdir" "$dest"
    rm -rf "$tmp"
}

# pkg_stage_path 返回当前包 staging 中的 prefix 路径
pkg_prefix_dir() {
    echo "$PKG_STAGE$PREFIX"
}

# merge_stage：把单包 staging 合并进总 staging
merge_stage() {
    local name="$1"
    log "$name: 合并到总 staging"
    mkdir -p "$STAGE_DIR"
    (cd "$PKG_STAGE" && tar cf - .) | (cd "$STAGE_DIR" && tar xf -) \
        || die "$name 合并 staging 失败"
}

# gnu_configure <额外参数...>：在包源码目录内执行常规 autoconf 交叉配置
gnu_configure() {
    ./configure \
        --host="$TARGET_TRIPLE" \
        --prefix="$PREFIX" \
        --disable-static --enable-shared \
        "$@"
}

# stage_install：make install 到单包 staging
stage_install() {
    make install DESTDIR="$PKG_STAGE" "$@"
}

# fix_la_paths：改写当前包 staging 内所有 .la 文件的 libdir
# libtool 生成的 .la 文件里 libdir 可能是两种值：
#   1. 设备路径 $PREFIX/lib（--prefix 指定的设备路径，libtool 默认行为）
#   2. per-pkg-stage 路径 $PKG_STAGE$PREFIX/lib（libtool --mode=install 写入的 install 目标）
# 下游包 libtool 链接时会读 .la 找依赖库路径，CI 主机上设备路径不存在导致
# "libxxx.la is not a valid libtool archive"。改写为 staging 实际路径
# （merge_stage 后下游从 STAGE_DIR$PREFIX 访问）。
#
# 关键难点：$stage_libdir = $STAGE_DIR + $dev_libdir，包含 $dev_libdir 子串。
# 直接 s{$dev_libdir}{$stage_libdir}g 会把 $stage_libdir 内的 $dev_libdir 也替换，
# 导致 $STAGE_DIR$STAGE_DIR$PREFIX/lib 双重前缀。
# 同样 $pkg_stage_libdir = $PKG_STAGE + $dev_libdir 也包含 $dev_libdir 子串。
#
# 解决：sentinel 三步替换。先把所有"已修复"路径（$stage_libdir / $pkg_stage_libdir）
# 暂存为 sentinel，再替换 $dev_libdir，最后恢复 sentinel。
# 这样无论 libdir 原值是设备路径还是 per-pkg-stage 路径都能正确处理。
fix_la_paths() {
    local la stage_libdir dev_libdir pkg_stage_libdir sentinel
    dev_libdir="$PREFIX/lib"
    stage_libdir="$STAGE_DIR$PREFIX/lib"
    pkg_stage_libdir="$PKG_STAGE$PREFIX/lib"
    sentinel="__HAISA_LIBDIR_SENTINEL_5F8A3B__"
    for la in "$PKG_STAGE$PREFIX"/lib/*.la; do
        [ -f "$la" ] || continue
        # libdir='...' 行：强制改为 stage_libdir（不论原值）
        sed -i "s|^libdir='[^']*'|libdir='$stage_libdir'|" "$la"
        # dependency_libs 里的路径：sentinel 三步替换避免双重前缀
        perl -i -pe "s{\\Q$stage_libdir\\E}{$sentinel}g" "$la"
        perl -i -pe "s{\\Q$pkg_stage_libdir\\E}{$sentinel}g" "$la"
        perl -i -pe "s{\\Q$dev_libdir\\E}{$stage_libdir}g" "$la"
        perl -i -pe "s{\\Q$sentinel\\E}{$stage_libdir}g" "$la"
    done
}

# make_deb：把当前包 PKG_STAGE 打成 Debian .deb
# 参数:
#   $1 depends  逗号分隔的依赖包列表（可空）
#   $2 desc     包描述（可空，默认 "$PKG_NAME package"）
# 产物: $DIST_DIR/packages/<name>_<version>_aarch64.deb
# 设计:
#   - 调用 lib/mk-deb.sh 构造 ar 归档（debian-binary + control.tar.gz + data.tar.gz）
#   - data.tar.gz 根 = $PKG_STAGE$PREFIX（相对路径，设备端 dpkg -i --instdir=$PREFIX 落位）
#   - Architecture 固定 aarch64（Termux 惯例，不用 arm64）
make_deb() {
    local depends="${1:-}"
    local desc="${2:-$PKG_NAME package}"
    local deb_name="${PKG_NAME}_${PKG_VERSION}_aarch64.deb"
    local deb_path="$DIST_DIR/packages/$deb_name"

    mkdir -p "$DIST_DIR/packages"
    bash "$BS_ROOT/lib/mk-deb.sh" \
        "$PKG_NAME" "$PKG_VERSION" \
        "$PKG_STAGE$PREFIX" \
        "$deb_path" \
        "$depends" "$desc"
}
