#!/data/data/com.haisades/files/usr/bin/bash
# pip wrapper —— haisa-des pip 接管层
#
# 设计原则：
#   1. 优先查本地 wheels-index.json（命中预编译 wheel → 下载 → sha256 校验 → pip install <local.whl> --no-index --no-deps）
#   2. 版本匹配：能匹配本地版本就用本地；版本不符直接报错（不回退 PyPI）
#   3. 依赖拓扑展开：本地 wheel 命中后，递归查 depends 字段，把依赖也优先从本地装
#   4. 未命中本地索引 → 直接报错（haisa-des 仓库无此包）
#   5. 未拦截的子命令（list/show/uninstall/freeze/install -r 等）→ 透传给原版 pip.real
#
# 依赖：
#   - python3（解析 wheels-index.json 和 PEP 440 版本约束）
#   - curl / sha256sum / tar
#   需先 apt install python 才能用 pip
set -euo pipefail

# ------------------------------------------------------------------
# 路径与常量
# ------------------------------------------------------------------
PREFIX="${PREFIX:-/data/data/com.haisades/files/usr}"
INSTALLED_DIR="$PREFIX/var/installed"
CACHE_DIR="$PREFIX/var/cache/pkg"
WHEEL_CACHE_DIR="$CACHE_DIR/wheel-cache"
WHEELS_INDEX_FILE="$CACHE_DIR/wheels-index.json"
STATE_DIR="$PREFIX/var/pkg"

# 镜像表（与 apt 共享 MIRROR_FILE）
MIRROR_PREFIXES=(
    ""
    "https://ghproxy.com/"
    "https://gh-proxy.com/"
)
DEFAULT_MIRROR_INDEX=0
MIRROR_FILE="$STATE_DIR/mirror"

# Releases 仓库
RELEASE_REPO_OWNER="XION-HN"
RELEASE_REPO_NAME="haisa-des-repo"
GITHUB_BASE="https://github.com/${RELEASE_REPO_OWNER}/${RELEASE_REPO_NAME}"

# 原版 pip（python 包安装时同时生成 pip.real）
REAL_PIP="$PREFIX/bin/pip.real"

# ------------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------------
log()  { printf '\033[1;34m[pip]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ------------------------------------------------------------------
# 镜像管理（与 apt 共享 MIRROR_FILE）
# ------------------------------------------------------------------
get_mirror_index() {
    [ -f "$MIRROR_FILE" ] && cat "$MIRROR_FILE" 2>/dev/null || echo "$DEFAULT_MIRROR_INDEX"
}

apply_mirror_with_index() {
    local idx="$1" url="$2"
    [ "$idx" -lt 0 ] 2>/dev/null && idx="$DEFAULT_MIRROR_INDEX"
    [ "$idx" -ge "${#MIRROR_PREFIXES[@]}" ] && idx="$DEFAULT_MIRROR_INDEX"
    local prefix="${MIRROR_PREFIXES[$idx]}"
    [ -z "$prefix" ] && { echo "$url"; return; }
    case "$url" in
        https://github.com/*) echo "${prefix}${url}" ;;
        *) echo "$url" ;;
    esac
}

# 环形遍历镜像 + 指数退避重试下载
http_get_with_retry() {
    local url="$1" dest="$2"
    local user_mirror n max_retries backoff last_err
    user_mirror=$(get_mirror_index)
    n=${#MIRROR_PREFIXES[@]}
    max_retries=2
    backoff=1
    last_err=""
    local offset m attempt try_url
    for offset in $(seq 0 $((n - 1))); do
        m=$(( (user_mirror + offset) % n ))
        try_url=$(apply_mirror_with_index "$m" "$url")
        for attempt in $(seq 1 $max_retries); do
            log "GET $try_url (尝试 $attempt/$max_retries)"
            if curl -fL --connect-timeout 15 --max-time 600 \
                    -H "User-Agent: HaisaDes-pip/1.0" \
                    -o "$dest" "$try_url" 2>/dev/null; then
                return 0
            fi
            last_err="curl 失败: $try_url"
            warn "$last_err"
            [ "$attempt" -lt "$max_retries" ] && sleep "$backoff" && backoff=$((backoff * 2))
        done
    done
    die "所有镜像均失败: $last_err"
}

sha256_matches() {
    local file="$1" expected="$2"
    [ -z "$expected" ] && return 0
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

# 确保本地有 wheels-index.json；无则从 Releases 拉
ensure_wheels_index() {
    [ -f "$WHEELS_INDEX_FILE" ] && return 0
    mkdir -p "$CACHE_DIR"
    log "本地无 wheel 索引，从 Releases 拉取..."
    local url="$GITHUB_BASE/releases/latest/download/wheels-index.json"
    http_get_with_retry "$url" "$WHEELS_INDEX_FILE" || die "wheel 索引拉取失败"
    return 0
}

# ------------------------------------------------------------------
# 命令行解析：从 pip install <args> 提取要装的包列表
# ------------------------------------------------------------------
# 仅拦截"包名+可选版本约束"的形式；其他形式（URL/路径/-r/-e）直接透传给原版 pip
parse_install_args() {
    local specs=()
    local has_non_spec=0
    local skip_next=0
    local arg
    for arg in "$@"; do
        if [ "$skip_next" = "1" ]; then
            skip_next=0
            continue
        fi
        case "$arg" in
            -*) # 选项
                case "$arg" in
                    -r|--requirement|-c|--constraint|-e|--editable|-t|--target|\
                    -i|--index-url|--extra-index-url|-f|--find-links|\
                    --prefix|--src|--build|--download-cache|--src|\
                    --install-option|--global-option|--config-settings|\
                    --root|--root-dir)
                        skip_next=1
                        ;;
                esac
                case "$arg" in
                    -r|--requirement|-c|--constraint|-e|--editable|\
                    -i|--index-url|--extra-index-url|-f|--find-links|\
                    --prefix|--src|--build|--root|--root-dir)
                        has_non_spec=1
                        ;;
                esac
                continue
                ;;
            *)
                case "$arg" in
                    http://*|https://*|ftp://*)
                        has_non_spec=1
                        ;;
                    ./*|/*|~/*)
                        has_non_spec=1
                        ;;
                    *)
                        specs+=("$arg")
                        ;;
                esac
                ;;
        esac
    done

    [ "$has_non_spec" = "1" ] && return 1
    [ ${#specs[@]} -eq 0 ] && return 1

    local s
    for s in "${specs[@]}"; do
        echo "$s"
    done
    return 0
}

# ------------------------------------------------------------------
# 核心逻辑：用 python 解析索引、版本约束、依赖拓扑展开
# ------------------------------------------------------------------
resolve_specs_and_deps() {
    local specs_str="$1"
    python3 - "$WHEELS_INDEX_FILE" "$specs_str" <<'PYEOF'
import json, sys, re

index_file = sys.argv[1]
specs_str = sys.argv[2]
specs = [s.strip() for s in specs_str.split("\n") if s.strip()]

with open(index_file) as f:
    idx = json.load(f)
wheels = {w["name"].lower(): w for w in idx["wheels"]}

def parse_spec(spec):
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(.*)$", spec)
    if not m:
        return (spec.lower().replace("_", "-"), "")
    name = m.group(1).lower().replace("_", "-")
    constraint = m.group(2).strip()
    return (name, constraint)

def parse_version(v):
    parts = []
    for seg in re.split(r"[\.\-]", v):
        for piece in re.findall(r"\d+|[A-Za-z]+", seg):
            parts.append(int(piece) if piece.isdigit() else piece)
    return tuple(parts)

def version_satisfies(ver, constraint):
    if not constraint:
        return True
    ver_tuple = parse_version(ver)
    for clause in constraint.split(","):
        clause = clause.strip()
        m = re.match(r"^(==|>=|<=|!=|~=|>|<)?\s*(.+)$", clause)
        if not m:
            continue
        op = m.group(1) or "=="
        target = m.group(2).strip()
        target_tuple = parse_version(target)
        if op == "==":
            if ver_tuple != target_tuple:
                return False
        elif op == "!=":
            if ver_tuple == target_tuple:
                return False
        elif op == ">=":
            if ver_tuple < target_tuple:
                return False
        elif op == "<=":
            if ver_tuple > target_tuple:
                return False
        elif op == ">":
            if ver_tuple <= target_tuple:
                return False
        elif op == "<":
            if ver_tuple >= target_tuple:
                return False
        elif op == "~=":
            if len(target_tuple) < 1:
                continue
            if ver_tuple < target_tuple:
                return False
            upper = list(target_tuple[:-1])
            if upper:
                for i in range(len(upper) - 1, -1, -1):
                    if isinstance(upper[i], int):
                        upper[i] = upper[i] + 1
                        break
                if ver_tuple >= tuple(upper):
                    return False
    return True

def expand_deps(name, visited):
    name_norm = name.lower().replace("_", "-")
    if name_norm in visited:
        return []
    visited.add(name_norm)
    if name_norm not in wheels:
        return []
    result = []
    for dep_spec in wheels[name_norm].get("depends", []):
        dep_name, dep_constraint = parse_spec(dep_spec)
        if dep_name not in wheels:
            # 本地索引无此依赖 → 整个安装失败（不回退 PyPI）
            raise RuntimeError(f"依赖 {dep_spec} 不在 haisa-des 仓库（pip 不支持 PyPI 回退）")
        dep_w = wheels[dep_name]
        if not version_satisfies(dep_w["version"], dep_constraint):
            raise RuntimeError(f"依赖 {dep_spec} 本地版本 {dep_w['version']} 不满足约束")
        for d in expand_deps(dep_name, visited):
            if d not in result:
                result.append(d)
    result.append(name_norm)
    return result

parsed = [parse_spec(s) for s in specs]
local_install = []
missing = []
visited = set()
for name, constraint in parsed:
    name_norm = name.lower().replace("_", "-")
    if name_norm not in wheels:
        missing.append(f"{name}{constraint}")
        continue
    w = wheels[name_norm]
    if constraint and not version_satisfies(w["version"], constraint):
        missing.append(f"{name}{constraint} (本地版本 {w['version']} 不满足约束)")
        continue
    try:
        order = expand_deps(name, visited)
    except RuntimeError as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(0)
    for n in order:
        ww = wheels[n]
        local_install.append({
            "name": ww["name"],
            "version": ww["version"],
            "filename": ww["filename"],
            "download_url": ww["download_url"],
            "sha256": ww["sha256"],
            "size": ww.get("size", 0),
        })

out = {"local": local_install, "missing": missing}
print(json.dumps(out))
PYEOF
}

# ------------------------------------------------------------------
# 下载并缓存 wheel
# ------------------------------------------------------------------
download_wheel() {
    local url="$1" sha="$2" filename="$3"
    mkdir -p "$WHEEL_CACHE_DIR"
    local wheel="$WHEEL_CACHE_DIR/$filename"

    if [ -f "$wheel" ] && sha256_matches "$wheel" "$sha"; then
        log "$filename: 已缓存"
        return 0
    fi

    log "$filename: 下载中..."
    http_get_with_retry "$url" "$wheel"

    if ! sha256_matches "$wheel" "$sha"; then
        rm -f "$wheel"
        die "$filename: sha256 校验失败"
    fi
}

# ------------------------------------------------------------------
# 主流程：pip install 拦截
# ------------------------------------------------------------------
handle_install() {
    command -v python3 >/dev/null 2>&1 || die "pip 需要 python3，请先 apt install python"
    command -v curl >/dev/null 2>&1 || die "pip 需要 curl，应已随 bootstrap 安装"

    # 有 -U/--upgrade 等选项 → 透传给原版 pip
    local arg
    for arg in "$@"; do
        case "$arg" in
            -U|--upgrade|-I|--ignore-installed|--force-reinstall|--reinstall|\
            --no-index|--no-build-isolation|--no-binary|--only-binary)
                log "检测到 $arg 选项，透传给原版 pip.real"
                exec "$REAL_PIP" install "$@"
                ;;
        esac
    done

    local specs_str
    specs_str=$(parse_install_args "$@") || {
        log "参数含非包规格（URL/路径/-r/-e），透传给原版 pip.real"
        exec "$REAL_PIP" install "$@"
    }

    [ -z "$specs_str" ] && {
        log "无包规格可解析，透传给原版 pip.real"
        exec "$REAL_PIP" install "$@"
    }

    ensure_wheels_index

    local resolve_result
    resolve_result=$(resolve_specs_and_deps "$specs_str")

    # 检查解析错误（如依赖缺失本地）
    local has_error
    has_error=$(echo "$resolve_result" | python3 -c "import json,sys; r=json.load(sys.stdin); print('yes' if 'error' in r else 'no')" 2>/dev/null || echo "yes")
    if [ "$has_error" = "yes" ]; then
        local err_msg
        err_msg=$(echo "$resolve_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', '未知错误'))")
        die "$err_msg"
    fi

    local local_count missing_count
    local_count=$(echo "$resolve_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['local']))")
    missing_count=$(echo "$resolve_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['missing']))")

    # 未命中本地索引 → 直接报错（不回退 PyPI）
    if [ "$missing_count" -gt 0 ]; then
        local missing_list
        missing_list=$(echo "$resolve_result" | python3 -c "
import json, sys
r = json.load(sys.stdin)
for m in r['missing']:
    print('  - ' + m)
")
        die "以下包不在 haisa-des 仓库（pip 不支持 PyPI 回退，请用 apt install 或联系维护者添加 wheel）:\n$missing_list"
    fi

    [ "$local_count" = "0" ] && die "无包可装"

    log "从 haisa-des 仓库装 $local_count 个包（含依赖）"
    local local_pkgs
    local_pkgs=$(echo "$resolve_result" | python3 -c "
import json, sys
r = json.load(sys.stdin)
for w in r['local']:
    print(w['filename'] + '|' + w['download_url'] + '|' + w['sha256'] + '|' + w['name'])
")
    local line
    while IFS='|' read -r filename url sha name; do
        [ -z "$filename" ] && continue
        download_wheel "$url" "$sha" "$filename"
        local wheel_path="$WHEEL_CACHE_DIR/$filename"
        log "pip.real install --no-index --no-deps $filename"
        if ! "$REAL_PIP" install --no-index --no-deps "$wheel_path"; then
            die "$name 本地 wheel 安装失败"
        fi
    done <<< "$local_pkgs"

    log "✓ 完成"
}

# ------------------------------------------------------------------
# 主入口
# ------------------------------------------------------------------
main() {
    [ $# -eq 0 ] && exec "$REAL_PIP"

    # 检查 pip.real 是否存在（python 是否已安装）
    [ -x "$REAL_PIP" ] || die "pip.real 不存在，请先 apt install python"

    local cmd="$1"; shift
    case "$cmd" in
        install)
            [ $# -eq 0 ] && exec "$REAL_PIP" install
            handle_install "$@"
            ;;
        *)
            # 其他子命令（uninstall/list/show/freeze/download/wheel/hash/help/config）
            # 透明传递给原版 pip.real
            exec "$REAL_PIP" "$cmd" "$@"
            ;;
    esac
}

main "$@"
