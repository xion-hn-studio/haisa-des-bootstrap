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
#    设计变更（v0.7.1+）: 全部符号链接都剥离到 SYMLINKS.txt，由 App 端
#    BootstrapInstaller.extractAndPrepare() 用 Os.symlink() 重建。
#    之前版本仅剥离别名链接、保留 SONAME，但 Python zipfile 无法存储 symlink
#    （z.write 调 os.stat 跟随符号链接，symlink 目标不存在时报错），
#    故统一剥离。
#
#    App 端重建逻辑见 BootstrapInstaller.java 第 138-155 行:
#      读取 SYMLINKS.txt 每行 "linkpath\ttarget"
#      link.delete(); Os.symlink(target, link.getAbsolutePath())
#    若 App 端 Os.symlink 失败（SELinux/权限），SONAME 链接缺失会导致
#    "CANNOT LINK EXECUTABLE" 或 "Method has died unexpectedly"。
#    修复方向: App 端加错误日志 + fallback 实体文件拷贝（待后续）。
SYMLINKS_TXT="$STAGE_DIR/SYMLINKS.txt"
: > "$SYMLINKS_TXT"
count=0
while IFS= read -r l; do
    rel="${l#"$SROOT"/}"
    tgt="$(readlink "$l")"
    printf '%s\t%s\n' "$rel" "$tgt" >> "$SYMLINKS_TXT"
    rm -f "$l"
    count=$((count + 1))
done < <(find "$SROOT" -type l)
log "符号链接 $count 条已记录到 SYMLINKS.txt（App 端重建）"

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

# 3) .deb 包已在 build.sh build_one 阶段打好（dist/packages/<name>_<ver>_aarch64.deb）
#    make-bootstrap.sh 只负责打 bootstrap.zip（含全部 staging，供 App 端首装）
#    后续 make-apt-repo.sh 扫描 dist/packages/*.deb 生成 Debian 仓库元数据
log ".deb 包已在 build 阶段打好: $DIST_DIR/packages/"
ls -1 "$DIST_DIR/packages/"*.deb 2>/dev/null | sed 's/^/  /' || warn "无 .deb 包（先运行 ./build.sh build all）"

log "产物:"
du -h "$OUT" 2>/dev/null | sed 's/^/  /'
sha256sum "$OUT" | sed 's/^/  /'
