# openjdk-17 —— OpenJDK 17 JDK（复用 Termux 预编译 aarch64 .deb，做 prefix 重定向）
#
# 方案 B（调研结论）：Termux 已完成 bionic 适配（30-50 个 patch），
# 官方 OpenJDK 上游不支持 Android target，自行交叉编译需 2-4 周。
# 这里只做: 下载 .deb → 解压 → sed 替换 prefix → patchelf 重写 RPATH → 落位 staging
#
# Termux openjdk-17 v17.0.20 单一包（92MB 下载 / 213MB 安装后）
# 安装路径: $PREFIX/lib/jvm/java-17-openjdk/
#
# 依赖策略:
#   haisa-des 已有（dpkg Depends 声明，不重复打包）:
#     libiconv, libjpeg-turbo, zlib, freetype, libpng, expat, ca-certificates
#   额外下载并集成进本包 .deb（haisa-des 没有，随 openjdk-17 一起装）:
#     libandroid-shmem   SysV shm 仿真（bionic 无 shmget）
#     libandroid-spawn   posix_spawn（旧 bionic 不完整）
#     libandroid-sysv-semaphore  SysV 信号量（alsa-lib 依赖）
#     alsa-lib           ALSA 音频库（JDK libjsound.so NEEDED libasound.so.2）
#     littlecms          色彩管理（JDK NEEDED liblcms2.so.2）
#     fontconfig         字体配置（JDK 字体渲染硬依赖）
#     ca-certificates-java  Java keystore 格式证书（SSL/TLS）
#     resolv-conf        DNS 解析配置
#
#   注意: Termux 原始 Depends 含 alsa-plugins（拉 pulseaudio 整条依赖链，过重）。
#   JDK 实际只需 alsa-lib（libasound.so.2），音频后端插件非必需。
#   故用 alsa-lib 替代 alsa-plugins，避免 pulseaudio/dbus/libsndfile 等重依赖。

PKG_NAME="openjdk-17"
PKG_VERSION="17.0.20"
PKG_SRC_URL="https://packages.termux.dev/apt/termux-main/pool/main/o/openjdk-17/openjdk-17_17.0.20_aarch64.deb"
PKG_SRC_SHA256="8eb45796aa8a216ac2054847e6ed3c073c3ef44407d9212154824b270b59f7ea"
PKG_SRC_DIR="openjdk-17"
PKG_DESC="OpenJDK 17 JDK (aarch64, bionic-adapted from Termux)"

# Termux prefix（.deb 内文件路径前缀）
TERMUX_PREFIX="/data/data/com.termux/files/usr"

# 额外依赖 .deb（haisa-des staging 没有的，随本包一起打包）
# 格式: "url sha256"
OPENJDK_DEP_DEBS=(
    "https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb 0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6"
    "https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-spawn/libandroid-spawn_0.3_aarch64.deb 7988fa788ef48ab5da9660443905a2e4099ac36221739d72f5c39acc644b4d1c"
    "https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-sysv-semaphore/libandroid-sysv-semaphore_0.1-1_aarch64.deb c3369a92814690d56278d0455ae6df7bf2ad7678ae9543e86d1e3aa433937c69"
    "https://packages.termux.dev/apt/termux-main/pool/main/a/alsa-lib/alsa-lib_1.2.16.1_aarch64.deb 34d850de4cf6a832b638a125ac2b029a46697e7a44c66f88fb388486c93314a5"
    "https://packages.termux.dev/apt/termux-main/pool/main/l/littlecms/littlecms_2.19.1_aarch64.deb 274f732a186563beca204f5d016d30cac8e5c24f7c4395b60881f9613eddf1a1"
    "https://packages.termux.dev/apt/termux-main/pool/main/f/fontconfig/fontconfig_2.18.2_aarch64.deb f8770203011f61389251e2fcfc5738cb2caeb7d852cb70e80637a7749affd44b"
    "https://packages.termux.dev/apt/termux-main/pool/main/c/ca-certificates-java/ca-certificates-java_1:2026.07.16_all.deb 0f66142aa47c905f35fb92c9035193349239707c9a9f916773629101a71ea4ac"
    "https://packages.termux.dev/apt/termux-main/pool/main/r/resolv-conf/resolv-conf_1.3_aarch64.deb ab541abac8e0c81709cd7ca4a02bcfa0d60ba1f4bfe7fd6dce4a694a4a9dfffa"
)

# 解压 .deb 到指定目录（提取 data.tar，GNU tar 自动识别压缩格式）
_deb_extract() {
    local deb="$1" dest="$2"
    local tmp; tmp="$(mktemp -d)"
    ( cd "$tmp" && ar x "$deb" ) || { rm -rf "$tmp"; die "ar x 失败: $deb"; }
    local data_tar
    data_tar="$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)"
    [ -n "$data_tar" ] || { rm -rf "$tmp"; die ".deb 内无 data.tar: $deb"; }
    mkdir -p "$dest"
    tar -xf "$data_tar" -C "$dest" || { rm -rf "$tmp"; die "tar 解压失败: $data_tar"; }
    rm -rf "$tmp"
}

# 替换 ELF 的 RPATH 前缀（保留 RPATH 结构，只替换 Termux prefix → haisa-des prefix）
# 无 RPATH 的 ELF 跳过（不强制添加，避免破坏 Termux 原始链接行为）
_patch_elf_rpath() {
    local f="$1"
    local old_rpath new_rpath
    old_rpath="$(patchelf --print-rpath "$f" 2>/dev/null)" || return 0
    [ -n "$old_rpath" ] || return 0
    new_rpath="${old_rpath//$TERMUX_PREFIX/$PREFIX}"
    [ "$old_rpath" = "$new_rpath" ] && return 0
    patchelf --set-rpath "$new_rpath" "$f" 2>/dev/null || \
        warn "patchelf --set-rpath 失败: $f"
}

pkg_prepare_src() {
    # fetch_pkg 已下载主 openjdk-17 .deb 到 $CACHE_DIR
    # 这里下载额外依赖 .deb，并全部解压到 $SRC_DIR/$PKG_SRC_DIR
    local src="$SRC_DIR/$PKG_SRC_DIR"
    rm -rf "$src"; mkdir -p "$src"

    log "openjdk-17: 解压主 .deb"
    _deb_extract "$CACHE_DIR/openjdk-17_17.0.20_aarch64.deb" "$src"

    # 下载并解压依赖 .deb
    local line url sha fname cache_file
    for line in "${OPENJDK_DEP_DEBS[@]}"; do
        url="${line% *}"; sha="${line##* }"; fname="${url##*/}"
        cache_file="$CACHE_DIR/$fname"
        if [ -f "$cache_file" ] && echo "$sha  $cache_file" | sha256sum -c - >/dev/null 2>&1; then
            log "openjdk-17 dep $fname: 缓存命中"
        else
            log "openjdk-17 dep $fname: 下载"
            curl -fSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
                -o "$cache_file" "$url" || die "下载失败: $fname"
            echo "$sha  $cache_file" | sha256sum -c - >/dev/null 2>&1 || die "sha256 失败: $fname"
        fi
        _deb_extract "$cache_file" "$src"
    done

    log "openjdk-17: 全部 .deb 解压完成"
    # 显示目录结构（调试用）
    log "openjdk-17: 目录结构:"
    find "$src" -maxdepth 5 -type d 2>/dev/null | head -25 | sed 's/^/  /'
}

pkg_build() {
    # cwd = $SRC_DIR/$PKG_SRC_DIR
    # 目录结构: data/data/com.termux/files/usr/...
    local src_prefix="data/data/com.termux/files/usr"
    local jvm_rel="lib/jvm/java-17-openjdk"
    local jvm_dir="$src_prefix/$jvm_rel"

    [ -d "$jvm_dir" ] || die "openjdk-17: .deb 内未找到 $jvm_dir"

    # 1) prefix 替换：所有文本文件中 Termux prefix → haisa-des prefix
    #    ELF 二进制不替换（java 用 dladdr 推导 JAVA_HOME，无硬编码绝对路径）
    #    grep -rIl 只列文本文件（-I 排除二进制）
    log "openjdk-17: 替换 prefix $TERMUX_PREFIX → $PREFIX"
    local txt_count=0
    local f
    while IFS= read -r f; do
        sed -i "s|${TERMUX_PREFIX}|${PREFIX}|g" "$f" && txt_count=$((txt_count + 1))
    done < <(grep -rIl "$TERMUX_PREFIX" "$src_prefix" 2>/dev/null)
    log "openjdk-17: 替换 $txt_count 个文本文件的 prefix"

    # 2) patchelf 重写 RPATH（只替换 RPATH 里的 Termux prefix，保留结构）
    #    JDK 的 .so 和 bin/ 下二进制都有 RPATH 指向 Termux lib 目录
    command -v patchelf >/dev/null || die "openjdk-17: 需要 patchelf（CI 需 apt-get install patchelf）"
    local elf_count=0
    while IFS= read -r f; do
        _patch_elf_rpath "$f" && elf_count=$((elf_count + 1))
    done < <(find "$src_prefix" -type f -exec sh -c 'file "$1" | grep -q "ELF" && echo "$1"' _ {} \; 2>/dev/null)
    log "openjdk-17: 处理 $elf_count 个 ELF 的 RPATH"

    # 3) 生成 fontconfig 配置（用 Android 系统字体 /system/fonts）
    #    Termux 的 fontconfig .deb 自带 fonts.conf 也已被 prefix 替换，
    #    但为确保 CJK 字体可用，覆盖一份指向 /system/fonts 的配置。
    local etc_fonts="$src_prefix/etc/fonts"
    mkdir -p "$etc_fonts/conf.d"
    cat > "$etc_fonts/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- haisa-des: fontconfig 配置，指向 Android 系统字体 -->
<fontconfig>
  <dir>/system/fonts</dir>
  <dir>${PREFIX}/share/fonts</dir>
  <cachedir>${PREFIX}/var/cache/fontconfig</cachedir>
  <include ignore_missing="yes">${PREFIX}/etc/fonts/conf.d</include>
  <!-- CJK 字体回退: sans-serif 追加 Noto Sans CJK -->
  <match target="pattern">
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="append" binding="strong">
      <string>Noto Sans CJK SC</string>
    </edit>
  </match>
</fontconfig>
EOF

    # 4) 落位到 staging：src_prefix/* → $PKG_STAGE$PREFIX/
    mkdir -p "$PKG_STAGE$PREFIX"
    cp -rf "$src_prefix"/* "$PKG_STAGE$PREFIX/"
    log "openjdk-17: 落位 $PKG_STAGE$PREFIX"

    # 5) 创建 bin/ 下 symlink（java/javac 等指向 jvm 内部）
    #    make-bootstrap.sh 会用实体文件替换 symlink，App 端解压后直接可用
    local bin_dir="$PKG_STAGE$PREFIX/bin"
    local jvm_bin="$PKG_STAGE$PREFIX/$jvm_rel/bin"
    mkdir -p "$bin_dir"
    if [ -d "$jvm_bin" ]; then
        local tool
        for tool in java javac jar javadoc jshell jcmd jinfo jmap jstack jstat \
                    jps keytool rmiregistry rmic serialver jpackage jlink jmod \
                    jdeprscan jdeps jfr jhsdb; do
            [ -f "$jvm_bin/$tool" ] && ln -sf "../$jvm_rel/bin/$tool" "$bin_dir/$tool"
        done
        log "openjdk-17: 创建 bin/ 下 symlink: $(ls "$jvm_bin" | wc -l) 个工具"
    fi

    # 6) JAVA_HOME profile.d 脚本（登录 shell 自动设置环境变量）
    local profile_dir="$PKG_STAGE$PREFIX/etc/profile.d"
    mkdir -p "$profile_dir"
    cat > "$profile_dir/java.sh" <<EOF
# OpenJDK 17 环境变量（haisa-des）
export JAVA_HOME="${PREFIX}/lib/jvm/java-17-openjdk"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF

    # 7) conffiles 清单（升级时受保护的配置文件）
    cat > "$PKG_STAGE$PREFIX/.conffiles" <<'EOF'
etc/profile.d/java.sh
etc/fonts/fonts.conf
lib/jvm/java-17-openjdk/conf/security/java.security
lib/jvm/java-17-openjdk/conf/security/java.policy
lib/jvm/java-17-openjdk/conf/net.properties
lib/jvm/java-17-openjdk/conf/sound.properties
lib/jvm/java-17-openjdk/conf/management/management.properties
lib/jvm/java-17-openjdk/lib/jvm.cfg
lib/jvm/java-17-openjdk/release
EOF

    # 8) 检查关键文件存在性
    local java_bin="$PKG_STAGE$PREFIX/$jvm_rel/bin/java"
    local libjvm="$PKG_STAGE$PREFIX/$jvm_rel/lib/server/libjvm.so"
    [ -f "$java_bin" ] || warn "openjdk-17: java 二进制缺失: $java_bin"
    [ -f "$libjvm" ] || warn "openjdk-17: libjvm.so 缺失: $libjvm"

    log "openjdk-17: 构建完成"
    log "  JAVA_HOME=${PREFIX}/lib/jvm/java-17-openjdk"
    du -sh "$PKG_STAGE$PREFIX" 2>/dev/null | sed 's/^/  体积: /'
}
