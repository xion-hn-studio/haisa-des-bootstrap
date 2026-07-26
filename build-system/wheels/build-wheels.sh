#!/usr/bin/env bash
# HaisaDes wheel 构建入口
# 用法:
#   ./build-wheels.sh list                 列出全部 wheel 包
#   ./build-wheels.sh build <pkg...|all>    构建/下载 wheel，产物进 dist/wheels/
#   ./build-wheels.sh clean                 清理
#
# 两种构建方法:
#   - download: 从 PyPI 拉取已发布的 aarch64 manywheel（numpy/Pillow/lxml 等）
#               通过 PyPI JSON API 动态匹配符合 py_tag + aarch64 的 wheel
#   - source:   用 build-system staging 里的 Python + SDL2 系列，交叉编译 wheel
#               需 CI 注册 QEMU binfmt（B4 阶段 pygame 用）
set -euo pipefail

WHEELS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BS_ROOT="$(cd "$WHEELS_ROOT/.." && pwd)"
# shellcheck source=../config.sh
source "$BS_ROOT/config.sh"
# shellcheck source=../lib/common.sh
source "$BS_ROOT/lib/common.sh"

DIST_WHEELS_DIR="$BS_ROOT/dist/wheels"
ALL_WHEELS="numpy Pillow lxml pygame"

# 包定义: 每个 wheels/packages/<name>/build.sh 定义:
#   PKG_NAME, PKG_VERSION, PKG_METHOD (download|source),
#   PKG_PY_TAG (download 方法用，如 cp313),
#   PKG_SRC_URL, PKG_SRC_SHA256, PKG_SRC_DIR (source 方法用)

load_wheel_pkg() {
    local name="$1"
    local f="$WHEELS_ROOT/packages/$name/build.sh"
    [ -f "$f" ] || die "缺少 wheel 包定义: $f"
    PKG_NAME="" PKG_VERSION="" PKG_METHOD="" PKG_PY_TAG=""
    PKG_SRC_URL="" PKG_SRC_SHA256="" PKG_SRC_DIR=""
    unset -f pkg_build 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$f"
    [ -n "$PKG_NAME" ] && [ -n "$PKG_METHOD" ] || die "$f 元数据不完整"
}

# 用 staging 的 Python 解释器（aarch64），需 QEMU binfmt 支持
staging_python() {
    local py="$STAGE_DIR$PREFIX/bin/python3"
    [ -x "$py" ] || die "staging 中无 python3: $py（先运行 ./build.sh build all）"
    echo "$py"
}

# 用 PyPI JSON API 查找匹配 aarch64 + py_tag 的 wheel URL
# 用法: resolve_pypi_wheel <name> <version> <py_tag>
# 输出: <wheel_url> <wheel_sha256>
resolve_pypi_wheel() {
    local name="$1" version="$2" py_tag="$3"
    local json_url="https://pypi.org/pypi/$name/$version/json"
    log "$name: 查询 PyPI JSON $json_url"
    curl -sL --retry 3 --connect-timeout 30 "$json_url" | \
    python3 - "$py_tag" <<'PYEOF'
import json, sys
py_tag = sys.argv[1]
d = json.load(sys.stdin)
# 优先匹配 manylinux aarch64 wheel
matches = []
for u in d.get("urls", []):
    fn = u["filename"]
    if not fn.endswith(".whl"):
        continue
    if "aarch64" not in fn:
        continue
    # py_tag 形如 cp313；wheel 文件名形如 numpy-2.1.0-cp313-cp313-manylinux...aarch64.whl
    # 简单包含匹配（同时接受 abi3/none 抽象 ABI 的 wheel）
    parts = fn.split("-")
    # wheel 文件名格式: {name}-{ver}-{py}-{abi}-{plat}-{build?}.whl
    if len(parts) >= 5:
        wheel_py = parts[2]
        # wheel_py 形如 cp313 或 py3（纯 Python wheel）
        if py_tag in wheel_py or wheel_py == "py3":
            matches.append((fn, u["url"], u.get("digests", {}).get("sha256", "")))
if not matches:
    sys.stderr.write(f"未找到匹配 {py_tag}+aarch64 的 wheel\n")
    sys.exit(1)
# 优先 manylinux，其次 linux
many = [m for m in matches if "manylinux" in m[0]]
chosen = many[0] if many else matches[0]
print(f"{chosen[1]} {chosen[2]}")
PYEOF
}

build_one_wheel() {
    local name="$1"
    load_wheel_pkg "$name"
    local outdir="$DIST_WHEELS_DIR"
    mkdir -p "$outdir"
    case "$PKG_METHOD" in
        download)
            [ -n "$PKG_PY_TAG" ] || die "$name: download 方法需 PKG_PY_TAG"
            local resolved url sha
            resolved=$(resolve_pypi_wheel "$PKG_NAME" "$PKG_VERSION" "$PKG_PY_TAG") \
                || die "$name: PyPI 未找到 aarch64 wheel（py_tag=$PKG_PY_TAG）"
            url=$(echo "$resolved" | awk '{print $1}')
            sha=$(echo "$resolved" | awk '{print $2}')
            local fname="${url##*/}"
            local dest="$outdir/$fname"
            if [ -f "$dest" ] && [ -n "$sha" ]; then
                if echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
                    log "$name: 已下载且校验通过，跳过"
                    return 0
                fi
                rm -f "$dest"
            fi
            log "$name: 下载 $fname"
            curl -fSL --retry 3 --connect-timeout 30 -o "$dest" "$url" \
                || die "$name wheel 下载失败"
            if [ -n "$sha" ]; then
                echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1 \
                    || die "$name wheel sha256 校验失败"
            fi
            log "$name: 完成 ($fname)"
            ;;
        source)
            # 需要 CI 注册 QEMU binfmt 让 staging 的 aarch64 python3 可在 x86_64 host 运行
            # shellcheck source=lib/cross-env.sh
            source "$WHEELS_ROOT/lib/cross-env.sh"
            local tmpsrc="$WORK_DIR/wheel-src/$name"
            rm -rf "$tmpsrc"; mkdir -p "$tmpsrc"
            fetch_pkg "$name" "$PKG_SRC_URL" "$PKG_SRC_SHA256"
            extract_pkg "$name" "$PKG_SRC_URL" "$PKG_SRC_DIR"
            cp -a "$SRC_DIR/$PKG_SRC_DIR/." "$tmpsrc/"
            log "$name: 用 staging Python 交叉编译 wheel"
            ( cd "$tmpsrc" && \
              "$(staging_python)" -m pip wheel --no-deps --no-build-isolation -w "$outdir" . ) \
                || die "$name wheel 编译失败"
            log "$name: 完成"
            ;;
        *)
            die "未知 PKG_METHOD=$PKG_METHOD（可选: download, source）"
            ;;
    esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
    list)
        for p in $ALL_WHEELS; do
            load_wheel_pkg "$p"
            printf "%-12s %-10s %-10s %s\n" "$p" "$PKG_VERSION" "$PKG_METHOD" "${PKG_WHEEL_URL:-${PKG_SRC_URL:-py_tag=$PKG_PY_TAG}}"
        done
        ;;
    build)
        targets="${*:-all}"
        [ "$targets" = "all" ] && set -- $ALL_WHEELS || set -- $targets
        log "构建 wheels: $*  (output: $DIST_WHEELS_DIR)"
        mkdir -p "$DIST_WHEELS_DIR"
        for p in "$@"; do build_one_wheel "$p"; done
        log "全部完成。wheels: $DIST_WHEELS_DIR"
        ;;
    clean)
        rm -rf "$DIST_WHEELS_DIR" "$WORK_DIR/wheel-src"
        log "已清理 wheels 产物"
        ;;
    *)
        sed -n '2,15p' "$0"; exit 1 ;;
esac
