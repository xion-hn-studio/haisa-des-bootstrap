#!/usr/bin/env bash
# make-wheels-index.sh —— 扫描 dist/wheels/*.whl 生成 wheels-index.json
#
# 索引格式供 App 侧 PackageManager / pip wrapper 消费：
#   - download_url: 指向 GitHub Releases 资产 URL
#   - sha256: 设备端下载后校验
#   - filename: wheel 文件名（pip install 用）
#   - depends: 依赖列表（PEP 440 字符串，如 ["numpy>=1.20,<2.0"]）
#              优先用 wheel 子包 build.sh 的 PKG_PYTHON_DEPENDS（手动维护，覆盖自动提取）
#              否则从 wheel metadata 的 Requires-Dist 自动提取（剔除环境标记 extras）
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
import os, sys, json, hashlib, subprocess, re, zipfile

wheel_dir = sys.argv[1]
index_file = sys.argv[2]
repo_url = sys.argv[3]
release_tag = sys.argv[4]
target_abi = sys.argv[5]
bs_root = sys.argv[6]

# 从 wheel 包定义提取字段：PKG_DESC（描述）、PKG_PYTHON_DEPENDS（手动覆盖依赖）
def get_pkg_meta(name):
    """返回 (desc, python_depends_str)"""
    f = f"{bs_root}/wheels/packages/{name}/build.sh"
    if not os.path.exists(f):
        return ("", "")
    try:
        # 用 bash source 执行，分别 echo 两个变量
        script = (
            f'source "{f}" 2>/dev/null && '
            f'echo "${{PKG_DESC:-}}" && '
            f'echo "---SEP---" && '
            f'echo "${{PKG_PYTHON_DEPENDS:-}}"'
        )
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=5)
        parts = r.stdout.split("---SEP---\n", 1)
        desc = parts[0].strip() if parts else ""
        deps = parts[1].strip() if len(parts) > 1 else ""
        return (desc, deps)
    except Exception:
        return ("", "")

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
    return (name, version, py_tag, abi_tag, platform_tag, build_tag)

def extract_requires_dist(wheel_path):
    """从 wheel 的 METADATA 文件提取 Requires-Dist，返回依赖列表。
    剔除带 extras 的（如 "numpy [test]"）、剔除环境标记复杂的（如 "python_version<'3.8'"），
    保留 PEP 440 版本约束（如 "numpy>=1.20,<2.0"）。
    返回 ["numpy>=1.20,<2.0", "python-dateutil"] 形式。"""
    deps = []
    try:
        with zipfile.ZipFile(wheel_path) as z:
            # METADATA 文件在 *.dist-info/METADATA
            meta_names = [n for n in z.namelist()
                          if n.endswith(".dist-info/METADATA")]
            if not meta_names:
                return deps
            with z.open(meta_names[0]) as mf:
                for line in mf:
                    line = line.decode("utf-8", errors="replace").strip()
                    if not line.startswith("Requires-Dist:"):
                        continue
                    req = line[len("Requires-Dist:"):].strip()
                    # 跳过带 extras 的：numpy [test]
                    if re.search(r"\[\s*\w+", req):
                        continue
                    # 跳过带环境标记的（platform/python_version/implementation_name 等）
                    if ";" in req:
                        continue
                    # 去掉末尾的空白和注释
                    req = req.split("#")[0].strip()
                    if req:
                        deps.append(req)
    except Exception as e:
        sys.stderr.write(f"  warn: 提取 METADATA 失败 {wheel_path}: {e}\n")
    return deps

def normalize_dep_name(req):
    """从 PEP 440 依赖字符串提取包名（小写、下划线转连字符）。
    如 'numpy>=1.20,<2.0' → 'numpy'
       'python-dateutil' → 'python-dateutil'"""
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)", req)
    if not m:
        return req
    return m.group(1).lower().replace("_", "-")

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

    # 反查 build.sh：取 PKG_DESC 和 PKG_PYTHON_DEPENDS
    # 目录名与 wheel 文件名首字段可能大小写不同（如 Pillow 在两者都是 Pillow）
    # 用 build.sh 目录列表做不区分大小写匹配
    pkg_dir_name = None
    packages_dir = f"{bs_root}/wheels/packages"
    if os.path.isdir(packages_dir):
        for d in os.listdir(packages_dir):
            if d.lower() == name.lower():
                pkg_dir_name = d
                break
    desc, manual_deps = ("", "")
    if pkg_dir_name:
        desc, manual_deps = get_pkg_meta(pkg_dir_name)

    # 依赖解析优先级：手动 PKG_PYTHON_DEPENDS > 自动提取 Requires-Dist
    if manual_deps:
        # 手动依赖是空格分隔，转列表
        depends = [d.strip() for d in manual_deps.split() if d.strip()]
    else:
        depends = extract_requires_dist(full_path)

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
        "desc": desc,
        "depends": depends,
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
    deps_str = ", ".join(w["depends"]) if w["depends"] else "(无依赖)"
    print(f"  {w['name']}-{w['version']}  {w['py_tag']}-{w['abi_tag']}-{w['platform_tag']}  {w['size']//1024}KB  deps: {deps_str}")
PYEOF

log "wheels-index.json 生成完成: $INDEX_FILE"
