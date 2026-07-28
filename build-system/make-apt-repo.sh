#!/usr/bin/env bash
# make-apt-repo.sh —— 扫描 dist/packages/*.deb 生成 Debian 仓库元数据
#
# 生成结构:
#   dists/stable/Release                         仓库元信息
#   dists/stable/main/binary-aarch64/Packages    包列表（文本）
#   dists/stable/main/binary-aarch64/Packages.gz 包列表（gzip）
#   dists/stable/main/binary-aarch64/Release    组件元信息
#
# 注意: InRelease/Release.gpg 由 make-keyring.sh sign 生成（GPG RSA 2048 签名）。
#       本脚本只生成未签名的 Release/Packages/Packages.gz；
#       CI 流水线串联: make-apt-repo.sh → make-keyring.sh sign。
#       设备端 apt 通过 $PREFIX/etc/apt/trusted.gpg.d/haisa-des.gpg 验签（随 apt 包安装）。
#
# 用法:
#   ./make-apt-repo.sh
#   RELEASE_TAG=v1.0.0 ./make-apt-repo.sh
set -euo pipefail

BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BS_ROOT/config.sh"
source "$BS_ROOT/lib/common.sh"

PKG_DIR="$DIST_DIR/packages"
REPO_ROOT="$DIST_DIR/apt-repo"     # 仓库根（含 dists/ + pool/）
DIST_NAME="stable"
COMPONENT="main"
ARCH="aarch64"

[ -d "$PKG_DIR" ] || die "packages 目录不存在: $PKG_DIR（先运行 ./make-bootstrap.sh）"

# 清理旧仓库（保证幂等）
rm -rf "$REPO_ROOT"
mkdir -p "$REPO_ROOT/dists/$DIST_NAME/$COMPONENT/binary-$ARCH"
mkdir -p "$REPO_ROOT/pool/$COMPONENT"

log "生成 Debian 仓库元数据 ($REPO_ROOT)..."

# ---- 1. 把所有 .deb 拷到 pool/main/<首字母>/<包名>/ ----
# Debian 标准布局（与 Debian 官方仓库一致）:
#   pool/main/a/apt/apt_2.8.1_aarch64.deb
#   pool/main/libl/liblz4/liblz4_1.10.0_aarch64.deb
#   pool/main/libg/libgnutls/libgnutls_3.8.9_aarch64.deb
# 首字母规则:
#   - 包名以 "lib" 开头：取前 4 字符（lib + 下一字母），如 libg / libl / libi
#   - 其他包：取首字母（小写）
# 这样可避免一个目录下文件过多（数百 .deb 时扁平 pool 会撑爆 inode）
deb_list=()
for deb in "$PKG_DIR"/*.deb; do
    [ -f "$deb" ] || continue
    fn="$(basename "$deb")"
    # 从 <name>_<version>_<arch>.deb 提取包名
    pkg_name="${fn%%_*}"
    # 计算 Debian pool 首字母段
    if [[ "$pkg_name" == lib* ]]; then
        # libfoo → libf（取 lib + 第 4 个字符）
        prefix="${pkg_name:0:4}"
    else
        prefix="${pkg_name:0:1}"
    fi
    prefix="$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
    pool_subdir="$REPO_ROOT/pool/$COMPONENT/$prefix/$pkg_name"
    mkdir -p "$pool_subdir"
    cp "$deb" "$pool_subdir/"
    deb_list+=( "$fn" )
done

[ ${#deb_list[@]} -gt 0 ] || die "无 .deb 包可索引（$PKG_DIR 下无 *.deb）"

# ---- 2. 生成 Packages 文件 ----
# Packages 文件字段（每个包一段）:
#   Package / Version / Architecture / Maintainer / Installed-Size
#   Depends / Priority / Description / Filename / Size / MD5sum / SHA256
PACKAGES_FILE="$REPO_ROOT/dists/$DIST_NAME/$COMPONENT/binary-$ARCH/Packages"

python3 - "$REPO_ROOT" "$PKG_DIR" "$COMPONENT" "$ARCH" <<'PYEOF'
import os, sys, hashlib, subprocess, gzip

repo_root = sys.argv[1]
pkg_dir = sys.argv[2]
component = sys.argv[3]
arch = sys.argv[4]

pool_root = os.path.join(repo_root, "pool", component)
packages_path = os.path.join(repo_root, "dists", "stable", component, f"binary-{arch}", "Packages")

def md5sum(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def sha256sum(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_control(deb_path):
    """从 .deb 里提取 control.tar.gz，解析 control 文件字段"""
    import tarfile, io
    r = subprocess.run(
        ["ar", "p", deb_path, "control.tar.gz"],
        capture_output=True, check=True
    )
    with tarfile.open(fileobj=io.BytesIO(r.stdout), mode="r:gz") as tar:
        control_file = tar.extractfile("control")
        if control_file is None:
            return {}
        text = control_file.read().decode("utf-8")
    fields = {}
    current_key = None
    for line in text.splitlines():
        if line.startswith(" ") or line.startswith("\t"):
            if current_key:
                fields[current_key] += "\n" + line
        elif ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip()] = v.strip()
            current_key = k.strip()
    return fields

# 递归扫描 pool/main/<首字母>/<包名>/*.deb
deb_paths = []
for dirpath, dirnames, filenames in os.walk(pool_root):
    dirnames.sort()
    for fn in sorted(filenames):
        if fn.endswith(".deb"):
            deb_paths.append(os.path.join(dirpath, fn))

entries = []
for deb_path in deb_paths:
    # Filename: 相对仓库根的路径（apt 用此拼下载 URL）
    # 例: pool/main/a/apt/apt_2.8.1_aarch64.deb
    filename = os.path.relpath(deb_path, repo_root)
    fields = parse_control(deb_path)
    size = os.path.getsize(deb_path)
    md5 = md5sum(deb_path)
    sha = sha256sum(deb_path)
    entry = []
    entry.append(f"Package: {fields.get('Package', '')}")
    entry.append(f"Version: {fields.get('Version', '')}")
    entry.append(f"Architecture: {fields.get('Architecture', arch)}")
    entry.append(f"Maintainer: {fields.get('Maintainer', '')}")
    if "Installed-Size" in fields:
        entry.append(f"Installed-Size: {fields['Installed-Size']}")
    if "Depends" in fields:
        entry.append(f"Depends: {fields['Depends']}")
    entry.append(f"Priority: {fields.get('Priority', 'optional')}")
    desc = fields.get("Description", "")
    entry.append(f"Description: {desc}")
    entry.append(f"Filename: {filename}")
    entry.append(f"Size: {size}")
    entry.append(f"MD5sum: {md5}")
    entry.append(f"SHA256: {sha}")
    entries.append("\n".join(entry))

packages_content = "\n\n".join(entries) + "\n"

with open(packages_path, "w") as f:
    f.write(packages_content)

with gzip.open(packages_path + ".gz", "wb") as f:
    f.write(packages_content.encode("utf-8"))

print(f"Packages: {packages_path}")
print(f"  {len(entries)} 个包")
PYEOF

# ---- 3. 生成 Release 文件 ----
# Release 描述整个 dists/stable/ 目录的元信息
RELEASE_FILE="$REPO_ROOT/dists/$DIST_NAME/Release"

now=$(date -u "+a, %d %b %Y %H:%M:%S UTC")

# 计算 dists/stable/ 下所有文件的 md5/sha256/size（Release 里要列）
compute_sums() {
    local dir="$1"
    ( cd "$dir" && find . -type f | sed 's|^\./||' | sort | while read -r f; do
        local size md5 sha
        size=$(stat -c %s "$f")
        md5=$(md5sum "$f" | awk '{print $1}')
        sha=$(sha256sum "$f" | awk '{print $1}')
        printf ' %s %16d %s\n' "$md5" "$size" "$f"
        printf ' %s %s\n' "$sha" "$f"
    done )
}

{
    echo "Origin: haisa-des repository"
    echo "Label: haisa-des"
    echo "Suite: $DIST_NAME"
    echo "Codename: $DIST_NAME"
    echo "Date: $now"
    echo "Architectures: $ARCH"
    echo "Components: $COMPONENT"
    echo "Description: haisa-des package repository"
    echo "MD5Sum:"
    ( cd "$REPO_ROOT/dists/$DIST_NAME" && find . -type f | sed 's|^\./||' | sort | while read -r f; do
        size=$(stat -c %s "$f")
        md5=$(md5sum "$f" | awk '{print $1}')
        printf ' %s %16d %s\n' "$md5" "$size" "$f"
    done )
    echo "SHA256:"
    ( cd "$REPO_ROOT/dists/$DIST_NAME" && find . -type f | sed 's|^\./||' | sort | while read -r f; do
        size=$(stat -c %s "$f")
        sha=$(sha256sum "$f" | awk '{print $1}')
        printf ' %s %16d %s\n' "$sha" "$size" "$f"
    done )
} > "$RELEASE_FILE"

log "Release: $RELEASE_FILE"
log "仓库元数据生成完成: $REPO_ROOT"
log "  路径布局（Debian 标准）:"
log "    dists/$DIST_NAME/Release"
log "    dists/$DIST_NAME/$COMPONENT/binary-$ARCH/Packages"
log "    dists/$DIST_NAME/$COMPONENT/binary-$ARCH/Packages.gz"
log "    pool/$COMPONENT/<首字母>/<包名>/<deb>   # lib* 取前 4 字符（如 libg），其他取首字母"
