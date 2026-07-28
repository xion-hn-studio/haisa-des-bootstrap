#!/usr/bin/env bash
# mk-deb.sh —— 把 staging 目录打包成 .deb（不依赖 dpkg-deb，纯 ar + tar）
#
# 用法:
#   mk-deb.sh <pkg-name> <version> <staging-prefix-dir> <output.deb> [depends] [description]
#
# 产物 .deb 格式（ar 归档，Debian 标准）:
#   debian-binary      # "2.0\n"
#   control.tar.gz      # control / md5sums
#   data.tar.gz         # 实际文件，相对 staging-prefix-dir 根（即相对 $PREFIX）
#
# 设计要点:
#   - data.tar.gz 的根 = staging-prefix-dir（相对路径，不含 $PREFIX 完整路径）
#     设备端 dpkg -i --instdir=$PREFIX 安装时正确落位
#   - control 用 Debian 标准字段（Package/Version/Architecture/Maintainer/Depends/Priority/Description）
#   - Architecture 固定 aarch64（Termux 惯例，不用 arm64）
#   - md5sums 列出 data 里所有文件的 md5（dpkg 卸载时校验用）
set -euo pipefail

name="$1"
version="$2"
stage_dir="$3"     # staging 的 prefix 目录（$PKG_STAGE$PREFIX）
out_deb="$4"
depends="${5:-}"
description="${6:-$name package}"

[ -d "$stage_dir" ] || { echo "mk-deb: staging 不存在: $stage_dir" >&2; exit 1; }

work="$(mktemp -d)"
trap "rm -rf $work" EXIT

# ---- 1. debian-binary ----
printf '2.0\n' > "$work/debian-binary"

# ---- 2. control.tar.gz ----
mkdir -p "$work/control"

# control 文件
{
    echo "Package: $name"
    echo "Version: $version"
    echo "Architecture: aarch64"
    echo "Maintainer: haisa-des <noreply@haisa-des.local>"
    echo "Installed-Size: $(du -sk "$stage_dir" | awk '{print $1}')"
    [ -n "$depends" ] && echo "Depends: $depends"
    echo "Priority: optional"
    echo "Description: $description"
    echo " ."
    echo " Built by haisa-des-bootstrap CI."
} > "$work/control/control"

# md5sums（不含符号链接，仅普通文件；排除 staging 根的 .conffiles 元数据）
( cd "$stage_dir" && find . -type f ! -name '.conffiles' | sed 's|^\./||' | xargs md5sum 2>/dev/null ) > "$work/control/md5sums" || true

# conffiles：若 staging 根有 .conffiles 清单，复制到 control/ 并按 dpkg 规范绝对路径化
# 用法：build.sh 在 $PKG_STAGE$PREFIX/.conffiles 写入相对路径列表（每行一个，如 etc/apt/sources.list）
if [ -f "$stage_dir/.conffiles" ]; then
    # 转成绝对路径（dpkg 要求 /etc/... 格式），过滤空行和注释
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's|^\([^/]\)|/\1|' "$stage_dir/.conffiles" \
        > "$work/control/conffiles"
fi

# ---- 3. data.tar.gz（相对 staging-prefix-dir 根）----
# 用相对路径打包，确保 data.tar.gz 里是 bin/bash 而非完整路径
# 排除空目录（dpkg 不需要）和 staging 根的 .conffiles 元数据文件
( cd "$stage_dir" && find . -type f -o -type l | sed 's|^\./||' | grep -v '^\.conffiles$' | tar -czf "$work/data.tar.gz" -T - )

# 打包 control（含可选 conffiles）
conffiles_arg=""
[ -f "$work/control/conffiles" ] && conffiles_arg="conffiles"
( cd "$work/control" && tar -czf "$work/control.tar.gz" control md5sums $conffiles_arg )

# ---- 4. 组装 .deb（ar 归档）----
# Debian .deb 的 ar 归档顺序固定: debian-binary, control.tar.gz, data.tar.gz
ar rcs "$out_deb" \
    "$work/debian-binary" \
    "$work/control.tar.gz" \
    "$work/data.tar.gz"

echo "mk-deb: $out_deb ($(du -h "$out_deb" | awk '{print $1}'))"
