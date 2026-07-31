#!/usr/bin/env bash
# make-bootstrap.sh —— 把总 staging 打成 bootstrap zip + 每包独立 tar.gz
# zip 结构：根 = $PREFIX 内容（bin/ lib/ etc/ share/ tmp/）+ SYMLINKS.txt
# SYMLINKS.txt 每行: link路径<TAB>目标（均相对 prefix 根），App 安装时重建。
set -euo pipefail
BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BS_ROOT/config.sh"
source "$BS_ROOT/lib/common.sh"

SROOT="$STAGE_DIR$PREFIX"
[ -d "$SROOT/bin" ] || die "staging 为空（$SROOT），先运行 ./build.sh build all"

OUT_SUFFIX=""
[ "$VARIANT" = "test" ] && OUT_SUFFIX="-test"
OUT="$DIST_DIR/bootstrap-${TARGET_ABI}${OUT_SUFFIX}.zip"
mkdir -p "$DIST_DIR/packages"
rm -f "$OUT"

# 清理 libtool 归档（无运行时价值，且含宿主路径）
find "$SROOT" -name '*.la' -delete 2>/dev/null || true
mkdir -p "$SROOT/tmp"

# 1) 用实体文件替换所有符号链接
#    设计变更（v0.7.2+）: 不再剥离符号链接到 SYMLINKS.txt，
#    而是用实体文件拷贝替换所有符号链接。
#
#    原因:
#    - Python zipfile 不支持存储 symlink（z.write 调 os.stat 跟随符号链接）
#    - App 端 Os.symlink 在某些 Android 版本因 SELinux 限制失败
#    - fallback 实体拷贝逻辑需 App 端代码支持，升级链路复杂
#    - SONAME 链接（libz.so.1 等）缺失会导致 "CANNOT LINK EXECUTABLE"
#      或 "Method has died unexpectedly"
#
#    方案: 用 cp -Lf 跟随符号链接拷贝实体文件，替换所有符号链接。
#    zip 里全是实体文件，App 端解压后直接可用，不依赖 Os.symlink。
#    代价: zip 略大（重复 .so 副本），但可靠性优先。
SYMLINKS_TXT="$SROOT/SYMLINKS.txt"
: > "$SYMLINKS_TXT"   # 空文件（向后兼容 App 端读取逻辑）
replaced=0
failed=0
while IFS= read -r l; do
    # readlink -f 跟随符号链接链到最终实体文件
    real="$(readlink -f "$l" 2>/dev/null || true)"
    if [ -n "$real" ] && [ -f "$real" ]; then
        rm -f "$l"
        cp -f "$real" "$l"
        replaced=$((replaced + 1))
    else
        # 无法解析（如指向 staging 外的绝对路径），删除并记录
        rel="${l#"$SROOT"/}"
        tgt="$(readlink "$l")"
        printf '%s\t%s\n' "$rel" "$tgt" >> "$SYMLINKS_TXT"
        rm -f "$l"
        failed=$((failed + 1))
    fi
done < <(find "$SROOT" -type l)
log "符号链接处理: 实体替换 $replaced 条, 无法解析删除 $failed 条"

# 1.5) 补全 SONAME 实体文件
#   staging 里的 .so 文件可能缺少 SONAME 链接（如 libz.so.1.3.1 存在但 libz.so.1 缺失）。
#   原因: 上一轮 make-bootstrap.sh 可能已 rm 掉符号链接，或 make install 未创建。
#   ELF NEEDED 字段引用 SONAME（如 libz.so.1），缺失会导致动态链接器找不到库。
#   方案: 用 readelf 读 SONAME，为每个缺失的创建实体文件拷贝（非符号链接）。
soname_created=0
while IFS= read -r so; do
    soname=$(readelf -d "$so" 2>/dev/null | awk '/SONAME/ {print $NF}' | tr -d '[]')
    [ -n "$soname" ] || continue
    dir=$(dirname "$so")
    link="$dir/$soname"
    # 仅当 SONAME 文件不存在时创建（避免覆盖已有文件）
    if [ ! -e "$link" ]; then
        cp -f "$so" "$link"
        soname_created=$((soname_created + 1))
    fi
done < <(find "$SROOT" -name '*.so.*' -type f)
log "SONAME 实体文件补全: $soname_created 条"

# 1.6) 修正可执行权限
#   cp -f 拷贝的实体文件继承源权限，staging 里部分 .so 和 apt methods 可能是 600
#   （非可执行），导致设备端 "Permission denied" 运行 apt methods、加载 .so 失败。
#   Android 不依赖 unix 权限位加载 .so，但 execve 执行 apt methods 必须有 +x。
#   统一: bin/ 下所有文件 + lib/ 下所有文件 0755，确保可执行可读。
#   （lib/ 含 .so/.so.*/静态库/apt methods，0755 对静态库无副作用）
find "$SROOT/bin" -type f -exec chmod 0755 {} +
find "$SROOT/lib" -type f -exec chmod 0755 {} +
[ -d "$SROOT/libexec" ] && find "$SROOT/libexec" -type f -exec chmod 0755 {} +
log "权限修正: bin/ + lib/ 下所有文件 → 0755"

# 1.7) 生成 dpkg status 数据库
#   bootstrap.zip 预装了所有包的文件（staging 已 install），但 dpkg status 是空模板
#   （dpkg/build.sh 只 touch 了 0 字节 status）。
#   后果: 设备端 dpkg 认为所有预装包"未安装"，apt list 显示空，apt install ./x.deb
#   时依赖检查失败（dpkg 认为依赖的包没装）。
#
#   修复: 遍历 dist/packages/*.deb，提取 control 字段写入 status（标记 installed），
#   并生成 info/<pkg>.list（文件清单，供 dpkg -L / apt remove 使用）。
#   这样设备端 dpkg -l 能列出已装包，apt install ./xxx.deb 依赖检查能通过。
#
#   健壮性: dpkg-deb -f 对 Version 字段有严格校验（必须以数字开头），
#   若版本号不合规（如 libcxx-shared 旧版 "r29.0..."）会报错跳过。
#   这里用 ar + tar 手动解析 control 作为 fallback，确保所有 .deb 都进 status。
DPKG_ADMINDIR="$SROOT/var/lib/dpkg"
mkdir -p "$DPKG_ADMINDIR/info" "$DPKG_ADMINDIR/updates" \
         "$DPKG_ADMINDIR/triggers" "$DPKG_ADMINDIR/parts"
: > "$DPKG_ADMINDIR/status"
: > "$DPKG_ADMINDIR/available"

# 从 .deb 手动提取 control 文件内容（不依赖 dpkg-deb，支持 gz/xz）
# 用法: _extract_control <deb> → stdout 输出 control 文件内容
_extract_control() {
    local deb="$1" tmp ctrl_tar
    tmp="$(mktemp -d)"
    ( cd "$tmp" && ar x "$deb" ) 2>/dev/null || { rm -rf "$tmp"; return 1; }
    ctrl_tar="$(ls "$tmp"/control.tar.* 2>/dev/null | head -1)"
    [ -n "$ctrl_tar" ] || { rm -rf "$tmp"; return 1; }
    tar -xf "$ctrl_tar" -C "$tmp" ./control 2>/dev/null
    cat "$tmp/control" 2>/dev/null
    rm -rf "$tmp"
}

# 从 .deb 手动提取文件清单（不依赖 dpkg-deb -c，支持 gz/xz）
# 用法: _extract_filelist <deb> → stdout 输出绝对路径列表
_extract_filelist() {
    local deb="$1" tmp data_tar
    tmp="$(mktemp -d)"
    ( cd "$tmp" && ar x "$deb" ) 2>/dev/null || { rm -rf "$tmp"; return 1; }
    data_tar="$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)"
    [ -n "$data_tar" ] || { rm -rf "$tmp"; return 1; }
    tar -tf "$data_tar" 2>/dev/null | sed 's|^\./|/|'
    rm -rf "$tmp"
}

status_count=0
list_count=0
skip_count=0
for deb in "$DIST_DIR/packages/"*.deb; do
    [ -f "$deb" ] || continue
    # 跳过 STANDALONE 包：它们的文件不在 bootstrap.zip 里（只打 .deb 供 apt install），
    # 标记为已安装会导致 apt 误判 "already installed" 但文件不存在。
    deb_basename="$(basename "$deb")"
    is_standalone=false
    for sp in $STANDALONE_PACKAGES; do
        case "$deb_basename" in
            "${sp}"_*) is_standalone=true; break ;;
        esac
    done
    if $is_standalone; then
        log "  跳过 STANDALONE 包 status 注册: $deb_basename"
        continue
    fi
    # 优先用 dpkg-deb -f（快），失败则用 ar+tar 手动解析
    ctrl_content=""
    if dpkg-deb -f "$deb" Package >/dev/null 2>&1; then
        ctrl_content="$(dpkg-deb -f "$deb")"
    else
        ctrl_content="$(_extract_control "$deb")"
    fi
    [ -n "$ctrl_content" ] || { skip_count=$((skip_count + 1)); continue; }

    # 提取包名（从 control 内容）
    name=$(echo "$ctrl_content" | awk '/^Package:/ {print $2; exit}')
    [ -n "$name" ] || { skip_count=$((skip_count + 1)); continue; }

    # 写 status 段落: control 字段 + Status: install ok installed + 空行分隔
    echo "$ctrl_content" >> "$DPKG_ADMINDIR/status"
    echo "Status: install ok installed" >> "$DPKG_ADMINDIR/status"
    echo "" >> "$DPKG_ADMINDIR/status"
    status_count=$((status_count + 1))

    # 写 info/<pkg>.list: .deb 内文件清单（绝对路径格式，dpkg 标准）
    # 优先 dpkg-deb -c，失败则手动 ar+tar
    if dpkg-deb -c "$deb" >/dev/null 2>&1; then
        dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | sed 's/^\.//' > "$DPKG_ADMINDIR/info/$name.list"
    else
        _extract_filelist "$deb" > "$DPKG_ADMINDIR/info/$name.list" 2>/dev/null
    fi
    list_count=$((list_count + 1))
done
log "dpkg status 数据库: $status_count 个包, $list_count 个 .list 文件, $skip_count 跳过"

# 1.8) chmod var/ 和 etc/（dpkg 写 var/lib/dpkg/、apt 读 etc/apt/ 需要权限）
#   App 端 chmodDir 也会处理，但 make-bootstrap 层面先确保正确。
[ -d "$SROOT/var" ] && find "$SROOT/var" -type d -exec chmod 0755 {} + 2>/dev/null || true
[ -d "$SROOT/var" ] && find "$SROOT/var" -type f -exec chmod 0644 {} + 2>/dev/null || true
[ -d "$SROOT/etc" ] && find "$SROOT/etc" -type d -exec chmod 0755 {} + 2>/dev/null || true
[ -d "$SROOT/etc" ] && find "$SROOT/etc" -type f -exec chmod 0644 {} + 2>/dev/null || true
log "权限修正: var/ + etc/ 目录 0755, 文件 0644"

# 2) 打 zip（python3 zipfile，免依赖系统 zip）
python3 - "$SROOT" "$OUT" <<'PYEOF'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort(); filenames.sort()
        # 显式写入目录条目：空目录（如 tmp/）也要能在设备端重建
        arc_dir = os.path.relpath(dirpath, root)
        if arc_dir != ".":
            z.write(dirpath, arc_dir + "/")
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            arc = os.path.relpath(full, root)
            z.write(full, arc)
print("written:", out)
PYEOF

# 3) .deb 包已在 build.sh build_one 阶段打好（dist/packages/<name>_<ver>_aarch64.deb）
#    make-bootstrap.sh 只负责打 bootstrap.zip（含全部 staging，供 App 端首装）
#    后续 make-apt-repo.sh 扫描 dist/packages/*.deb 生成 Debian 仓库元数据
log ".deb 包已在 build 阶段打好: $DIST_DIR/packages/"
ls -1 "$DIST_DIR/packages/"*.deb 2>/dev/null | sed 's/^/  /' || warn "无 .deb 包（先运行 ./build.sh build all）"

log "产物:"
du -h "$OUT" 2>/dev/null | sed 's/^/  /'
sha256sum "$OUT" | sed 's/^/  /'
