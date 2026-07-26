#!/usr/bin/env bash
# make-wheels-index.sh —— 扫描 dist/wheels/*.whl 生成 wheels-index.json
#
# 索引格式供 App 侧 PackageManager 消费：
#   - download_url: 指向 GitHub Releases 资产 URL
#   - sha256: 设备端下载后校验
#   - filename: wheel 文件名（pip install 用）
#
# 用法:
#   ./make-wheels-index.sh
#   REPO_URL="https://github.com/XION-HN/haisa-des-repo" \
#     RELEASE_TAG="v1.0.0" ./make-wheels-index.sh
set -euo pipefail

BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BS_ROOT/config.sh"
source "$BS_ROOT/lib/common.sh"

REPO_URL="${REPO_URL:-https://github.com/XION-HN/haisa-des-repo}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG 未设置（CI 必须传真实 tag 名，如 v0.1.0）}"

WHEEL_DIR="$BS_ROOT/dist/wheels"
INDEX_FILE="$BS_ROOT/dist/wheels-index.json"

[ -d "$WHEEL_DIR" ] || die "wheels 目录不存在: $WHEEL_DIR（先运行 ./wheels/build-wheels.sh build all）"

log "生成 wheels-index.json 索引..."

python3 - "$WHEEL_DIR" "$INDEX_FILE" "$REPO_URL" "$RELEASE_TAG" "$TARGET_ABI" "$BS_ROOT" <<'PYEOF'
import os, sys, json, hashlib, subprocess, re

wheel_dir = sys.argv[1]
index_file = sys.argv[2]
repo_url = sys.argv[3]
release_tag = sys.argv[4]
target_abi = sys.argv[5]
bs_root = sys.argv[6]

# 从 wheel 包定义提取描述信息（PKG_DESC 可选）
def get_desc(name):
    f = f"{bs_root}/wheels/packages/{name}/build.sh"
    if not os.path.exists(f):
        return ""
    try:
        r = subprocess.run(
            ["bash", "-c", f'source "{f}" 2>/dev/null && echo "${{PKG_DESC:-}}"'],
            capture_output=True, text=True, timeout=5
        )
        return r.stdout.strip()
    except Exception:
        return ""

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_wheel_name(fn):
    """解析 wheel 文件名: {name}-{ver}-{py}-{abi}-{plat}[-{build}].whl
    返回 (name, version, py_tag, abi_tag, platform_tag, build_tag)"""
    base = fn[:-len(".whl")]
    parts = base.split("-")
    if len(parts) < 5:
        return None
    name = parts[0]
    version = parts[1]
    py_tag = parts[2]
    abi_tag = parts[3]
    platform_tag = parts[4]
    build_tag = parts[5] if len(parts) > 5 else ""
    # name 可能含下划线（wheel 规范：name 中的 - 在文件名里转成 _）
    # 这里反查 build.sh 的 PKG_NAME 兜底
    return (name, version, py_tag, abi_tag, platform_tag, build_tag)

wheels = []
for fn in sorted(os.listdir(wheel_dir)):
    if not fn.endswith(".whl"):
        continue
    full_path = os.path.join(wheel_dir, fn)
    parsed = parse_wheel_name(fn)
    if parsed is None:
        print(f"跳过无法解析的 wheel 文件名: {fn}", file=sys.stderr)
        continue
    name, version, py_tag, abi_tag, platform_tag, build_tag = parsed

    # 反查 build.sh 的 PKG_NAME 修正 name（如 Pillow 的 wheel 文件名是大写但 PKG_NAME 也是大写）
    # build.sh 的目录名小写，PKG_NAME 大小写由定义决定
    # 用文件名首字段做粗匹配即可（Pillow 在文件名里是 Pillow，目录是 Pillow）

    size = os.path.getsize(full_path)
    sha = sha256_of(full_path)

    base = repo_url.rstrip("/")
    if base.endswith("/releases"):
        base = base[: -len("/releases")]
    download_url = f"{base}/releases/download/{release_tag}/{fn}"

    wheels.append({
        "name": name,
        "version": version,
        "py_tag": py_tag,
        "abi_tag": abi_tag,
        "platform_tag": platform_tag,
        "build_tag": build_tag,
        "size": size,
        "sha256": sha,
        "filename": fn,
        "download_url": download_url,
        "desc": get_desc(name),
    })

index = {
    "repo_version": 1,
    "generated_at": subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]).decode().strip(),
    "abi": target_abi,
    "wheels": wheels,
}

with open(index_file, "w") as f:
    json.dump(index, f, indent=2, ensure_ascii=False)

print(f"索引写入: {index_file}")
print(f"wheel 数量: {len(wheels)}")
for w in wheels:
    print(f"  {w['name']}-{w['version']}  {w['py_tag']}-{w['abi_tag']}-{w['platform_tag']}  {w['size']//1024}KB")
PYEOF

log "wheels-index.json 生成完成: $INDEX_FILE"
