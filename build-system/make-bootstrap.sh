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
# 内置包（已包含在 bootstrap.zip 内的脚本/工具）：不打单独 tar.gz，也不进 packages.json
# - apt: 包管理器 CLI，依赖 bootstrap 已有命令；发布到 Releases 反而是冗余
# - pip: wrapper 脚本，接管 pip 命令优先查本地 wheel 索引；原版 pip 在此重命名为 pip.real
BUILTIN_PACKAGES="apt pip"

# 在打包前处理 pip wrapper：把原版 pip 重命名为 pip.real
# （pip 包的 staging 已含 wrapper 脚本，merge 后会覆盖原版 pip；这里先备份原版）
# 注意：pip wrapper 包 install 时已创建 pip3/pip3.13 → pip 符号链接，
# 但原版 python 包安装时也创建了 pip → pip3.13 的符号链接，会被 wrapper 包覆盖。
# 重命名原版 pip 入口（python 包提供），让 wrapper 能透传未拦截命令给原版。
# 必须在 pip 包合并到总 staging 之后、打 zip 之前做。
# （pip 包 build 顺序在 python 之后，merge_stage 已让 pip wrapper 覆盖了原版 pip；
#  这里针对 wrapper 包的特殊情况，重新整理 pip 入口）
real_pip="$SROOT/bin/pip.real"
orig_pip="$SROOT/bin/pip3.13"
if [ -x "$orig_pip" ] && [ ! -e "$real_pip" ]; then
    # wrapper 包已把 wrapper 装到 bin/pip，但 wrapper 需要 pip.real 作为原版入口
    # 此时 bin/pip3.13 是 python 包安装的原版入口，把它复制为 pip.real
    cp "$orig_pip" "$real_pip"
    log "已备份原版 pip 入口到 $real_pip"
fi
for stage in "$PKG_STAGE_ROOT"/*/; do
    name="$(basename "$stage")"
    [ -f "$stage/.done" ] || continue
    case " $BUILTIN_PACKAGES " in
        *" $name "*) log "跳过内置包 $name（已包含在 bootstrap.zip）"; continue ;;
    esac
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
