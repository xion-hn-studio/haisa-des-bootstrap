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
