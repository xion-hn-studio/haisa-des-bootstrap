#!/usr/bin/env bash
# fetch-termux-patches.sh —— 从 termux-packages 仓库拉取指定包的 patch 文件
#
# 设计目的：
#   - patch 文件最终会提交到本仓库（可审计、构建可复现、CI 无需联网拉 patch）
#   - 此脚本仅在 termux 上游 patch 更新后重新同步时手动运行
#
# 用法:
#   ./fetch-termux-patches.sh <pkg-name> <dest-dir>
#   ./fetch-termux-patches.sh apt packages/apt/patches
#   ./fetch-termux-patches.sh dpkg packages/dpkg/patches
set -euo pipefail

pkg="$1"
dest="$2"

[ -n "$pkg" ] && [ -n "$dest" ] || { echo "用法: $0 <pkg-name> <dest-dir>"; exit 1; }

mkdir -p "$dest"

work="$(mktemp -d)"
trap "rm -rf $work" EXIT

echo "fetch-termux-patches: 拉取 termux-packages/packages/$pkg ..."
cd "$work"
git clone --quiet --depth 1 --filter=blob:none --sparse \
    https://github.com/termux/termux-packages.git tp
cd tp
git sparse-checkout set --quiet "packages/$pkg"

src="packages/$pkg"
[ -d "$src" ] || { echo "fetch-termux-patches: termux 仓库无 packages/$pkg 目录" >&2; exit 1; }

count=0
for p in "$src"/*.patch; do
    [ -f "$p" ] || continue
    name="$(basename "$p")"
    cp -f "$p" "$dest/$name"
    count=$((count + 1))
    echo "  + $name"
done

if [ "$count" -eq 0 ]; then
    echo "fetch-termux-patches: $pkg 无 .patch 文件"
    exit 0
fi

echo "fetch-termux-patches: 拉取 $count 个 patch 到 $dest"
echo "请检查后 git add $dest/*.patch 提交到仓库"
