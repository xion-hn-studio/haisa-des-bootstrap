#!/usr/bin/env bash
# make-pip-repo.sh —— 扫描 dist/wheels/*.whl 生成 PEP 503 simple 索引
#
# PEP 503 Simple Repository API 布局:
#   simple/                                  仓库根
#   ├── index.html                           顶层索引（列出所有包名链接）
#   ├── <首字母>/
#   │   └── <规范化包名>/
#   │       ├── index.html                   该包所有版本 wheel 下载链接
#   │       └── <wheel>.whl                  实际 wheel 文件（与 index.html 同目录）
#   │
# 首字母规则（与 PyPI 一致）:
#   - 取规范化包名首字母（小写）
#   - 不区分 lib* （PyPI 不区分，pip 也是按首字母）
#
# 规范化包名（PEP 503）:
#   - 大写转小写
#   - 连续的 - _ . 替换为单个 -
#   - 例: Pillow → pillow; charset-normalizer → charset-normalizer
#
# pip 客户端使用:
#   pip install --index-url https://xion-hn.github.io/haisa-des-repo/pip/simple/ <pkg>
#   （或 pip.conf 配置 index-url）
#
# 与 make-wheels-index.sh 的关系:
#   - make-wheels-index.sh: 生成 wheels-index.json（App 端 Java PM 用，含 sha256 + depends）
#   - make-pip-repo.sh:     生成 PEP 503 simple（设备端 pip install 用，标准接口）
#   两者扫描同一个 dist/wheels/ 目录，互相独立
#
# 用法:
#   ./make-pip-repo.sh
#   REPO_URL="https://xion-hn.github.io/haisa-des-repo" ./make-pip-repo.sh
set -euo pipefail

BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BS_ROOT/config.sh"
source "$BS_ROOT/lib/common.sh"

# pip-repo 部署根（最终是 https://xion-hn.github.io/haisa-des-repo/pip/）
# Pages 部署后，pip 用 --index-url https://xion-hn.github.io/haisa-des-repo/pip/simple/
REPO_URL="${REPO_URL:-https://xion-hn.github.io/haisa-des-repo}"
PIP_REPO_ROOT="$DIST_DIR/pip-repo"

WHEEL_DIR="$DIST_DIR/wheels"
[ -d "$WHEEL_DIR" ] || die "wheels 目录不存在: $WHEEL_DIR（先运行 ./wheels/build-wheels.sh build all）"

# 清理旧 pip-repo（幂等）
rm -rf "$PIP_REPO_ROOT"
mkdir -p "$PIP_REPO_ROOT/simple"

log "生成 PEP 503 simple 索引 ($PIP_REPO_ROOT)..."

# Python 脚本: 扫描 wheels → 规范化包名 → 拷贝到首字母目录 → 生成 index.html
python3 - "$WHEEL_DIR" "$PIP_REPO_ROOT" "$REPO_URL" <<'PYEOF'
import os, sys, re, shutil, html

wheel_dir = sys.argv[1]
pip_root = sys.argv[2]
repo_url = sys.argv[3].rstrip("/")

simple_root = os.path.join(pip_root, "simple")

def normalize(name):
    """PEP 503 包名规范化: 大写转小写，连续 - _ . 替换为单个 -"""
    return re.sub(r"[-_.]+", "-", name).lower()

def parse_wheel_name(fn):
    """解析 wheel 文件名: {name}-{ver}-{py}-{abi}-{plat}[-{build}].whl
    返回 (raw_name, normalized_name, version, rest)"""
    base = fn[:-len(".whl")]
    parts = base.split("-")
    if len(parts) < 5:
        return None
    raw_name = parts[0]
    version = parts[1]
    return (raw_name, normalize(raw_name), version, parts[2:])

# 收集所有 wheel: {normalized_name: [(filename, raw_name, version, full_path)]}
packages = {}
for fn in sorted(os.listdir(wheel_dir)):
    if not fn.endswith(".whl"):
        continue
    parsed = parse_wheel_name(fn)
    if parsed is None:
        sys.stderr.write(f"warn: 无法解析 wheel 文件名: {fn}\n")
        continue
    raw_name, norm_name, version, _ = parsed
    full_path = os.path.join(wheel_dir, fn)
    packages.setdefault(norm_name, []).append({
        "filename": fn,
        "raw_name": raw_name,
        "version": version,
        "full_path": full_path,
    })

# 为每个包生成: simple/<首字母>/<规范化包名>/index.html + wheel 文件拷贝
pkg_names_sorted = sorted(packages.keys())
for norm_name in pkg_names_sorted:
    first_letter = norm_name[0].lower()
    pkg_dir = os.path.join(simple_root, first_letter, norm_name)
    os.makedirs(pkg_dir, exist_ok=True)

    # 拷贝所有版本的 wheel 到包目录
    for wheel in packages[norm_name]:
        dst = os.path.join(pkg_dir, wheel["filename"])
        shutil.copy2(wheel["full_path"], dst)

    # 生成 index.html（PEP 503 格式）
    # 每个 <a> href 指向 wheel 文件（相对路径）
    # 可选属性: data-requires-python（PEP 503）— 此处从 wheel METADATA 提取较复杂，暂不填
    lines = [
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        '  <meta charset="utf-8">',
        f"  <title>Links for {html.escape(norm_name)}</title>",
        "</head>",
        "<body>",
        f"  <h1>Links for {html.escape(norm_name)}</h1>",
        f"  <p>Package: {html.escape(norm_name)} ({len(packages[norm_name])} version(s))</p>",
        "  <ul>",
    ]
    # 按版本降序（pip 会优先选最新）
    wheels_sorted = sorted(packages[norm_name], key=lambda w: w["version"], reverse=True)
    for wheel in wheels_sorted:
        fn = wheel["filename"]
        # data-attributes 可选: data-requires-python="..."（PEP 503/PEP 599）
        # 这里只放链接（相对 URL），pip 会自动选合适 platform 的 wheel
        lines.append(f'    <li><a href="{html.escape(fn)}">{html.escape(fn)}</a></li>')
    lines += [
        "  </ul>",
        "</body>",
        "</html>",
        "",
    ]
    index_path = os.path.join(pkg_dir, "index.html")
    with open(index_path, "w") as f:
        f.write("\n".join(lines))

# 顶层 simple/index.html: 列出所有包名（首字母分组展示）
top_index = os.path.join(simple_root, "index.html")
lines = [
    "<!DOCTYPE html>",
    '<html lang="en">',
    "<head>",
    '  <meta charset="utf-8">',
    "  <title>haisa-des PEP 503 Simple Index</title>",
    "</head>",
    "<body>",
    "  <h1>haisa-des Python Package Index</h1>",
    f"  <p>{len(pkg_names_sorted)} packages</p>",
    "  <ul>",
]
for norm_name in pkg_names_sorted:
    first_letter = norm_name[0].lower()
    # PEP 503 顶层链接必须以 / 结尾
    url = f"{first_letter}/{norm_name}/"
    lines.append(f'    <li><a href="{html.escape(url)}">{html.escape(norm_name)}</a></li>')
lines += [
    "  </ul>",
    "</body>",
    "</html>",
    "",
]
with open(top_index, "w") as f:
    f.write("\n".join(lines))

# pip-repo 根 README.md（指引客户端如何使用）
readme_path = os.path.join(pip_root, "README.md")
with open(readme_path, "w") as f:
    f.write(f"""# haisa-des PEP 503 Python Package Index

Generated from dist/wheels/*.whl by `make-pip-repo.sh`.

## Usage (device-side)

```bash
# 临时使用（仅本次 install）
pip install --index-url {repo_url}/pip/simple/ <package>

# 永久配置（写入 pip.conf）
mkdir -p $PREFIX/etc
cat > $PREFIX/etc/pip.conf <<EOF
[global]
index-url = {repo_url}/pip/simple/
trusted-host = $(repo_url.split("//")[1].split("/")[0] if "//" in repo_url else repo_url)
EOF
```

## Layout

```
pip/
├── README.md
└── simple/
    ├── index.html                    # 顶层（列出所有包名）
    ├── <首字母>/
    │   └── <规范化包名>/
    │       ├── index.html            # 该包所有版本 wheel 链接
    │       └── <wheel>.whl           # 实际 wheel 文件
    └── ...
```

PEP 503 规范化规则: 大写转小写，连续 `-` `_` `.` 替换为单个 `-`。
""")

print(f"PEP 503 simple 索引生成完成: {simple_root}")
print(f"  包数量: {len(pkg_names_sorted)}")
print(f"  首字母分组:")
letters = sorted(set(n[0].lower() for n in pkg_names_sorted))
for letter in letters:
    pkgs = [n for n in pkg_names_sorted if n[0].lower() == letter]
    print(f"    {letter}/ ({len(pkgs)} 包): {', '.join(pkgs)}")
PYEOF

log "pip-repo 生成完成: $PIP_REPO_ROOT"
log "  pip 客户端用法:"
log "    pip install --index-url ${REPO_URL}/pip/simple/ <package>"
