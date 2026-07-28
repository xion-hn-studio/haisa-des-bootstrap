#!/usr/bin/env bash
# make-packages-index.sh —— 扫描 dist/packages/*.deb 生成 packages.json 索引
#
# M4 改造：从扫描 .tar.gz 改为扫描 .deb
#   - 包名/版本/依赖/描述从 .deb 的 control 提取（不依赖文件名解析）
#   - symlinks 字段移除（.deb 由 dpkg 安装，自动处理符号链接）
#   - download_url 指向 .deb 文件
#
# 注意：真 apt 用 make-apt-repo.sh 生成的 Debian Packages/Release 元数据。
#       本脚本的 packages.json 仅供 App 端 PackageManager（Java）兼容使用，
#       App 端改造为调 apt 后可废弃。
#
# 用法:
#   ./make-packages-index.sh
#   REPO_URL="https://github.com/XION-HN/haisa-des-repo" \
#     RELEASE_TAG="v1.0.0" ./make-packages-index.sh
set -euo pipefail

BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BS_ROOT/config.sh"
source "$BS_ROOT/lib/common.sh"

# Releases 下载 URL 前缀（到 <repo> 根，不含 /releases/download/...）
# 公开仓库的 release 资产 URL 形如:
#   https://github.com/<owner>/<repo>/releases/download/<tag>/<filename>
# 注意：GitHub 的 "latest" 别名只在 API 层生效，下载 URL 路径必须是真实 tag 名，
# 用 "latest" 作 RELEASE_TAG 会导致 download_url 全部 404。CI 必须传真实 tag。
# 仓库必须 public，否则 App 端无 token 拉不到索引和资产。
REPO_URL="${REPO_URL:-https://github.com/XION-HN/haisa-des-repo}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG 未设置（CI 必须传真实 tag 名，如 v0.1.0）}"

PKG_DIR="$DIST_DIR/packages"
INDEX_FILE="$DIST_DIR/packages.json"

[ -d "$PKG_DIR" ] || die "packages 目录不存在: $PKG_DIR（先运行 ./build.sh build all）"

log "生成 packages.json 索引（扫描 .deb）..."

# 用 python3 生成 JSON（避免 bash 拼接 JSON 的转义地狱）
# 从 .deb 的 control.tar.gz 提取 Package/Version/Depends/Description
python3 - "$PKG_DIR" "$INDEX_FILE" "$REPO_URL" "$RELEASE_TAG" <<'PYEOF'
import os, sys, json, hashlib, subprocess, io, tarfile

pkg_dir = sys.argv[1]
index_file = sys.argv[2]
repo_url = sys.argv[3]
release_tag = sys.argv[4]

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_control(deb_path):
    """从 .deb 里提取 control.tar.gz，解析 control 文件字段"""
    # ar 归档: debian-binary, control.tar.gz, data.tar.gz
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

packages = []
for fn in sorted(os.listdir(pkg_dir)):
    if not fn.endswith(".deb"):
        continue
    deb_path = os.path.join(pkg_dir, fn)
    fields = parse_control(deb_path)
    size = os.path.getsize(deb_path)
    sha = sha256_of(deb_path)

    # REPO_URL 统一为仓库根，拼出标准 release 资产下载 URL
    base = repo_url.rstrip("/")
    if base.endswith("/releases"):
        base = base[: -len("/releases")]
    download_url = f"{base}/releases/download/{release_tag}/{fn}"

    # Depends 从 control 提取（逗号分隔），转成列表
    depends_str = fields.get("Depends", "")
    depends = [d.strip().split(" ")[0] for d in depends_str.split(",") if d.strip()] if depends_str else []

    packages.append({
        "name": fields.get("Package", ""),
        "version": fields.get("Version", ""),
        "depends": depends,
        "size": size,
        "sha256": sha,
        "filename": fn,
        "download_url": download_url,
        # symlinks 字段移除：.deb 由 dpkg 安装，自动处理符号链接
        # 保留空列表兼容旧 App 端解析逻辑
        "symlinks": [],
    })

index = {
    "repo_version": 2,  # M4: 版本号升级，标识 .deb 格式
    "generated_at": subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]).decode().strip(),
    "format": "deb",  # 标识包格式（旧版 tar.gz 无此字段）
    "packages": packages,
}

with open(index_file, "w") as f:
    json.dump(index, f, indent=2, ensure_ascii=False)

print(f"索引写入: {index_file}")
print(f"包数量: {len(packages)}")
for p in packages:
    print(f"  {p['name']}_{p['version']}  {p['size']//1024}KB  deps={p['depends']}")
PYEOF

log "packages.json 生成完成: $INDEX_FILE"
