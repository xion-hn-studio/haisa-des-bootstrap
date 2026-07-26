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

# 1) 记录并剔除符号链接
SYMLINKS_TXT="$STAGE_DIR/SYMLINKS.txt"
: > "$SYMLINKS_TXT"
while IFS= read -r l; do
    rel="${l#"$SROOT"/}"
    tgt="$(readlink "$l")"
    printf '%s\t%s\n' "$rel" "$tgt" >> "$SYMLINKS_TXT"
    rm -f "$l"
done < <(find "$SROOT" -type l)
log "符号链接 $(wc -l < "$SYMLINKS_TXT") 条已记录"

# 2) 打 zip（python3 zipfile，免依赖系统 zip）
cp "$SYMLINKS_TXT" "$SROOT/SYMLINKS.txt"
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

# 3) 每包独立 tar.gz（路径相对 prefix 根，便于手动装包演练: tar -xzf x.tar.gz -C $PREFIX）
for stage in "$PKG_STAGE_ROOT"/*/; do
    name="$(basename "$stage")"
    [ -f "$stage/.done" ] || continue
    # 从包定义取版本号
    PKG_NAME="" PKG_VERSION=""
    unset -f pkg_build pkg_prepare_src 2>/dev/null || true
    source "$BS_ROOT/packages/$name/build.sh"
    pdir="$stage$PREFIX"
    [ -d "$pdir" ] || continue
    (cd "$pdir" && tar czf "$DIST_DIR/packages/${PKG_NAME}-${PKG_VERSION}-${TARGET_ABI}${OUT_SUFFIX}.tar.gz" .)
done

log "产物:"
du -h "$OUT" "$DIST_DIR/packages/"*.tar.gz 2>/dev/null | sed 's/^/  /'
sha256sum "$OUT" | sed 's/^/  /'
