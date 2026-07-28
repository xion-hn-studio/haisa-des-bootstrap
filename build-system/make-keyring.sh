#!/usr/bin/env bash
# make-keyring.sh —— GPG 密钥管理与 Debian 仓库 Release 签名
#
# 决策：
#   - 私钥：CI Secret 注入（HAISADES_GPG_PRIVATE_KEY），本地一次性生成
#   - 算法：RSA 2048（Termux/Debian 兼容）
#   - 产物：InRelease（cleartext 签名）+ Release.gpg（detached 双签）
#   - 公钥：随 apt 包发布到 $PREFIX/etc/apt/trusted.gpg.d/haisa-des.gpg
#
# 子命令:
#   init [<keyring-dir>]                    本地一次性生成密钥对（手动运行，仅一次）
#   export-pubkey <keyring-dir> <out.gpg>  导出公钥到 apt trusted.gpg.d/
#   export-private <keyring-dir>           导出私钥 ASCII（用于上传到 GitHub Secret）
#   import-private                          从 stdin 读取私钥 ASCII 导入到 CI 临时 keyring
#   sign <release-file>                     生成 InRelease + Release.gpg
#
# 用法:
#   # 本地一次性生成（手动）:
#   ./make-keyring.sh init .gpg
#   # → .gpg/pubring.gpg（公钥）+ .gpg/secring.gpg（私钥）+ .gpg/haisa-des.pub.asc（公钥 ASCII，提交仓库）
#
#   # 导出私钥 ASCII（手动，注入 GitHub Secret HAISADES_GPG_PRIVATE_KEY）:
#   ./make-keyring.sh export-private .gpg | pbcopy    # macOS
#   ./make-keyring.sh export-private .gpg > /tmp/private.asc
#
#   # apt 包构建时调用：把公钥拷进 staging 的 trusted.gpg.d/
#   ./make-keyring.sh export-pubkey .gpg packages/apt/trusted.gpg.d/haisa-des.gpg
#
#   # CI 中注入私钥并签 Release:
#   printf '%s' "$HAISADES_GPG_PRIVATE_KEY" | ./make-keyring.sh import-private
#   ./make-keyring.sh sign dist/apt-repo/dists/stable/Release
set -euo pipefail

BS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BS_ROOT/config.sh" 2>/dev/null || true
# common.sh 不一定提供 log，这里自己实现
log()  { printf '\033[1;34m[keyring]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# GPG 标识（密钥 UID），所有签名都用这个身份
GPG_NAME="haisa-des"
GPG_EMAIL="noreply@haisa-des.local"
GPG_UID="$GPG_NAME <$GPG_EMAIL>"
GPG_KEYTYPE="RSA"
GPG_KEYLENGTH="2048"
GPG_EXPIRE="2y"   # 2 年过期，到期前轮换密钥（旧密钥可在 trusted.gpg.d 多保留一段时间）

# CI 临时 keyring 路径（import-private 用，不污染系统 gpg）
CI_KEYRING="${HAISADES_GPG_KEYRING:-$BS_ROOT/.ci-keyring}"
GNUPGHOME="${GNUPGHOME:-}"   # 若调用方已设置则用之

# 公共 gpg 调用参数：无密码、loopback pinentry（CI 必需）、batch
gpg_common_args=(
    --batch
    --yes
    --pinentry-mode loopback
    --passphrase ""
    --no-tty
)

# 构造 GNUPGHOME 优先级：
#   1. 调用方已导出 → 用之
#   2. 子命令指定 keyring-dir → 用之
#   3. CI 模式 → 用 CI_KEYRING
setup_gnupghome() {
    local kr_dir="${1:-}"
    if [ -n "$GNUPGHOME" ] && [ -d "$GNUPGHOME" ]; then
        return 0
    fi
    if [ -n "$kr_dir" ]; then
        mkdir -p "$kr_dir"
        chmod 700 "$kr_dir"
        export GNUPGHOME="$kr_dir"
        return 0
    fi
    # CI 模式（import-private 后调用 sign）
    mkdir -p "$CI_KEYRING"
    chmod 700 "$CI_KEYRING"
    export GNUPGHOME="$CI_KEYRING"
}

# ---- init ----
cmd_init() {
    local kr_dir="${1:-$BS_ROOT/.gpg}"
    setup_gnupghome "$kr_dir"

    # 若已存在同 UID 的密钥则报错（避免误覆盖）
    if gpg "${gpg_common_args[@]}" --list-secret-keys --with-colons "$GPG_EMAIL" 2>/dev/null | grep -q '^sec'; then
        die "$kr_dir 已存在 $GPG_UID 的私钥（如需重新生成请先删除 keyring 目录）"
    fi

    log "生成 GPG 密钥对（$GPG_KEYTYPE $GPG_KEYLENGTH，UID=$GPG_UID，过期=$GPG_EXPIRE）..."

    # 批量生成密钥（无交互，无密码）
    gpg "${gpg_common_args[@]}" --gen-key <<EOF
%no-protection
Key-Type: $GPG_KEYTYPE
Key-Length: $GPG_KEYLENGTH
Key-Usage: sign
Name-Real: $GPG_NAME
Name-Email: $GPG_EMAIL
Expire-Date: $GPG_EXPIRE
%commit
EOF

    # 导出公钥 ASCII（提交仓库，供 apt 包构建时打包到 trusted.gpg.d/）
    local pub_asc="$kr_dir/haisa-des.pub.asc"
    gpg "${gpg_common_args[@]}" --armor --export "$GPG_EMAIL" > "$pub_asc"
    chmod 644 "$pub_asc"

    # 显示密钥指纹（设备端可用此校验公钥）
    local fpr
    fpr=$(gpg "${gpg_common_args[@]}" --with-colons --list-keys "$GPG_EMAIL" | awk -F: '/^fpr:/ {print $10; exit}')
    log "密钥生成完成"
    log "  Keyring 目录: $kr_dir"
    log "  公钥 ASCII:   $pub_asc"
    log "  指纹:         $fpr"
    log ""
    log "下一步:"
    log "  1. 把 $pub_asc 提交到仓库"
    log "  2. 运行: $0 export-private $kr_dir > /tmp/private.asc"
    log "  3. 把 /tmp/private.asc 内容作为 GitHub Secret HAISADES_GPG_PRIVATE_KEY 注入"
    log "  4. 把指纹 $fpr 也作为 Secret HAISADES_GPG_FINGERPRINT 注入（可选，sign 时自动从 keyring 找）"
}

# ---- export-pubkey <keyring-dir> <out.gpg> ----
# 导出二进制 OpenPGP 公钥（apt trusted.gpg.d/ 要求二进制格式，非 ASCII）
cmd_export_pubkey() {
    [ $# -ge 2 ] || die "用法: $0 export-pubkey <keyring-dir> <out.gpg>"
    local kr_dir="$1" out="$2"
    [ -d "$kr_dir" ] || die "keyring 目录不存在: $kr_dir"

    setup_gnupghome "$kr_dir"

    mkdir -p "$(dirname "$out")"
    gpg "${gpg_common_args[@]}" --export "$GPG_EMAIL" > "$out"
    # 校验产物非空
    [ -s "$out" ] || die "公钥导出失败：$out 为空"
    chmod 644 "$out"
    log "公钥导出: $out ($(du -h "$out" | awk '{print $1}'))"
}

# ---- export-private <keyring-dir> ----
# 导出私钥 ASCII（用于上传到 GitHub Secret）
# 注意：私钥不写到文件，输出到 stdout 避免落地
cmd_export_private() {
    [ $# -ge 1 ] || die "用法: $0 export-private <keyring-dir>"
    local kr_dir="$1"
    [ -d "$kr_dir" ] || die "keyring 目录不存在: $kr_dir"

    setup_gnupghome "$kr_dir"

    # 直接输出到 stdout，调用方重定向到文件或剪贴板
    gpg "${gpg_common_args[@]}" --armor --export-secret-keys "$GPG_EMAIL"
}

# ---- import-private ----
# 从 stdin 读取私钥 ASCII，导入到 CI 临时 keyring
cmd_import_private() {
    setup_gnupghome ""
    log "导入私钥到 CI 临时 keyring: $GNUPGHOME"
    gpg "${gpg_common_args[@]}" --import
    log "导入完成。可用密钥:"
    gpg "${gpg_common_args[@]}" --list-secret-keys "$GPG_EMAIL" 2>&1 | sed 's/^/  /'
}

# ---- sign <release-file> ----
# 生成 InRelease（cleartext 签名）+ Release.gpg（detached 二进制签名）
cmd_sign() {
    [ $# -ge 1 ] || die "用法: $0 sign <release-file>"
    local rel="$1"
    [ -f "$rel" ] || die "Release 文件不存在: $rel"

    # 若未设置 GNUPGHOME，用 CI keyring
    setup_gnupghome ""

    # 校验 keyring 有私钥
    gpg "${gpg_common_args[@]}" --list-secret-keys "$GPG_EMAIL" 2>/dev/null | grep -q 'sec' \
        || die "keyring 中无私钥（$GPG_EMAIL）。先运行 import-private 注入。"

    local dir rel_basename
    dir="$(dirname "$rel")"
    rel_basename="$(basename "$rel")"

    log "签名 Release: $rel"

    # ---- 1. InRelease（cleartext 签名，apt 默认用此校验）----
    # 现代 Debian 仓库的 InRelease 是 cleartext 签名：原文 + ASCII 签名块封装在一个文件
    # apt 优先下载 InRelease，省一次 HTTP 请求
    local inrel="$dir/InRelease"
    gpg "${gpg_common_args[@]}" \
        --local-user "$GPG_EMAIL" \
        --clearsign \
        --output "$inrel" \
        "$rel"
    [ -s "$inrel" ] || die "InRelease 生成失败"
    log "  InRelease:  $inrel ($(du -h "$inrel" | awk '{print $1}'))"

    # ---- 2. Release.gpg（detached 二进制签名，老版本 apt 兼容）----
    local detached="$dir/Release.gpg"
    gpg "${gpg_common_args[@]}" \
        --local-user "$GPG_EMAIL" \
        --detach-sign \
        --output "$detached" \
        "$rel"
    [ -s "$detached" ] || die "Release.gpg 生成失败"
    log "  Release.gpg: $detached ($(du -h "$detached" | awk '{print $1}'))"

    # ---- 3. 校验签名可被本 keyring 验证（自检）----
    if ! gpg "${gpg_common_args[@]}" --verify "$detached" "$rel" >/dev/null 2>&1; then
        die "自检失败：Release.gpg 签名验证未通过"
    fi
    if ! gpg "${gpg_common_args[@]}" --verify "$inrel" >/dev/null 2>&1; then
        die "自检失败：InRelease 签名验证未通过"
    fi
    log "自检通过：签名验证 OK"
}

# ---- verify <sig-file> [release-orig] [keyring-dir] ----
# 用本地公钥校验签名（CI/本地排查用）
#   verify <InRelease>                    # cleartext 自包含签名
#   verify <Release.gpg> <Release>        # detached 签名需原文件
#   verify <sig> <orig> <keyring-dir>     # 指定本地 keyring 验证
cmd_verify() {
    [ $# -ge 1 ] || die "用法: $0 verify <sig> [<release-orig>] [<keyring-dir>]"
    local sig="$1"
    local orig="${2:-}"
    local kr_dir="${3:-}"
    [ -f "$sig" ] || die "签名文件不存在: $sig"
    [ -z "$orig" ] || [ -f "$orig" ] || die "原文件不存在: $orig"

    # 若未指定 keyring-dir，使用 CI keyring（若存在），否则用默认 .gpg
    if [ -z "$kr_dir" ]; then
        if [ -d "$CI_KEYRING" ]; then
            kr_dir="$CI_KEYRING"
        else
            kr_dir="$BS_ROOT/.gpg"
        fi
    fi
    setup_gnupghome "$kr_dir"

    if [ -n "$orig" ]; then
        # detached 签名
        gpg "${gpg_common_args[@]}" --verify "$sig" "$orig"
    else
        # cleartext 签名（InRelease 自包含原文件）
        gpg "${gpg_common_args[@]}" --verify "$sig"
    fi
    log "签名验证通过"
}

# ---- 调度 ----
subcmd="${1:-}"
shift || true
case "$subcmd" in
    init)            cmd_init "$@" ;;
    export-pubkey)   cmd_export_pubkey "$@" ;;
    export-private)  cmd_export_private "$@" ;;
    import-private)  cmd_import_private "$@" ;;
    sign)            cmd_sign "$@" ;;
    verify)          cmd_verify "$@" ;;
    *)
        sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
        die "未知子命令: $subcmd（可用: init / export-pubkey / export-private / import-private / sign / verify）"
        ;;
esac
