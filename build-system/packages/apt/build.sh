# apt —— Debian 包管理器前端（真 apt 2.8.1，非脚本模拟）
#
# 源码：Debian 官方 apt 2.8.1 + Termux 14 个 Android 适配 patch
# patch 文件在 packages/apt/patches/，来源 termux-packages 仓库
# （用 lib/fetch-termux-patches.sh 同步，已落盘提交，CI 无需联网拉 patch）
#
# patch 用 @TERMUX_PREFIX@ 占位符，应用时 sed 替换为实际 $PREFIX
#
# Termux 专属 cmake 调整：
#   - FindBerkeley.cmake 移除 NO_DEFAULT_PATH（允许回退默认路径找 db.h）
#   - CMAKE_LIBRARY_PATH 添加 /usr/lib/aarch64-linux-gnu 和 Termux lib 路径
#   （NDK 交叉编译时这些路径不存在但无害）
PKG_NAME="apt"
PKG_VERSION="2.8.1"
PKG_SRC_URL="https://salsa.debian.org/apt-team/apt/-/archive/2.8.1/apt-2.8.1.tar.bz2"
PKG_SRC_SHA256="87ca18392c10822a133b738118505f7d04e0b31ba1122bf5d32911311cb2dc7e"
PKG_SRC_DIR="apt-2.8.1"

pkg_prepare_src() {
    extract_pkg "$PKG_NAME" "$PKG_SRC_URL" "$PKG_SRC_DIR"
    local src="$SRC_DIR/$PKG_SRC_DIR"

    # 应用 Termux 的 14 个 Android 适配 patch
    # patch 里用 @TERMUX_PREFIX@ 占位符，sed 替换为实际 $PREFIX
    # --forward: 跳过已应用的 patch（幂等）
    # --fuzz=3: 允许 context 模糊匹配（apt 版本差异 2.1.x vs 2.8.1）
    # --no-backup-if-mismatch: 不留 .orig 文件
    local patch_dir="$BS_ROOT/packages/apt/patches"
    local p
    for p in "$patch_dir"/*.patch; do
        [ -f "$p" ] || continue
        log "apt: 应用 patch $(basename "$p")"
        sed "s%@TERMUX_PREFIX@%$PREFIX%g" "$p" | \
            patch -d "$src" -p1 --forward --fuzz=3 --no-backup-if-mismatch || \
            warn "apt: patch $(basename "$p") 应用失败或已应用（忽略）"
    done

    # FindBerkeley.cmake 移除 NO_DEFAULT_PATH
    # Termux clang 找不到 db.h 时允许回退默认搜索路径
    local fb="$src/CMake/FindBerkeley.cmake"
    if [ -f "$fb" ] && grep -q 'NO_DEFAULT_PATH' "$fb"; then
        sed -i 's/NO_DEFAULT_PATH//' "$fb"
        log "apt: FindBerkeley.cmake 移除 NO_DEFAULT_PATH"
    fi
}

pkg_build() {
    # apt 用 CMake 构建
    mkdir -p build && cd build

    # CMAKE_LIBRARY_PATH: 添加系统库路径
    # - Termux lib: /data/data/com.termux/files/usr/lib（termux-local 工具链时必需）
    # - Debian 多架构: /usr/lib/aarch64-linux-gnu（CI 主机有 libdb 等）
    # NDK 交叉编译时这些路径不存在但 cmake 会忽略，无害
    local lib_paths="$STAGE_DIR$PREFIX/lib"
    [ -d /usr/lib/aarch64-linux-gnu ] && lib_paths="$lib_paths;/usr/lib/aarch64-linux-gnu"
    [ -d /data/data/com.termux/files/usr/lib ] && \
        lib_paths="$lib_paths;/data/data/com.termux/files/usr/lib"

    cmake .. \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -Wno-c++11-narrowing" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_FULL_LOCALSTATEDIR="$PREFIX" \
        -DCMAKE_INSTALL_LIBEXECDIR=lib \
        -DCMAKE_LIBRARY_PATH="$lib_paths" \
        -DCACHE_DIR="$PREFIX/var/cache/apt" \
        -DCOMMON_ARCH="$TARGET_ABI" \
        -DDPKG_DATADIR="$PREFIX/share/dpkg" \
        -DUSE_NLS=OFF \
        -DWITH_DOC=OFF \
        -DWITH_DOC_MANPAGES=ON \
        -DPERL_EXECUTABLE="$(command -v perl || echo /bin/false)"
    make -j"$JOBS"
    make install DESTDIR="$PKG_STAGE"

    # ---- 生成 apt 配置文件 ----
    # sources.list 指向 haisa-des 仓库（GitHub Pages 托管 Debian 仓库结构）
    # APT_REPO_URL 环境变量可覆盖默认 URL（部署方案确定后调整）
    # GitHub Releases 不支持 apt 目录结构，必须用 GitHub Pages 或类似静态托管
    local apt_repo_url="${APT_REPO_URL:-https://xion-hn.github.io/haisa-des-repo/apt-repo}"
    local etc_apt="$PKG_STAGE$PREFIX/etc/apt"
    mkdir -p "$etc_apt/apt.conf.d" \
             "$etc_apt/preferences.d" \
             "$etc_apt/sources.list.d" \
             "$etc_apt/auth.conf.d" \
             "$etc_apt/trusted.gpg.d"

    # sources.list: 仓库源（不再用 [trusted=yes]，由 trusted.gpg.d/haisa-des.gpg 验签）
    cat > "$etc_apt/sources.list" <<EOF
# haisa-des package repository
# 公钥在 $PREFIX/etc/apt/trusted.gpg.d/haisa-des.gpg（随 apt 包安装）
# Release/InRelease 由 make-keyring.sh sign 用 GPG RSA 2048 私钥签名
deb ${apt_repo_url} stable main
EOF

    # 公钥拷到 trusted.gpg.d/（apt 2.8.1 默认从这里加载信任公钥）
    # 来源优先级:
    #   1. $BS_ROOT/.gpg/haisa-des.gpg（make-keyring.sh init 后用 export-pubkey 生成二进制格式）
    #   2. $BS_ROOT/.gpg/haisa-des.pub.asc（ASCII 格式，gpg --dearmor 转二进制）
    #   3. 都没有则跳过并告警（构建可继续，但设备端需手动 apt-key add 或用 trusted=yes 临时降级）
    local gpg_pubkey_bin="$etc_apt/trusted.gpg.d/haisa-des.gpg"
    if [ -f "$BS_ROOT/.gpg/haisa-des.gpg" ]; then
        cp "$BS_ROOT/.gpg/haisa-des.gpg" "$gpg_pubkey_bin"
        log "apt: 公钥来源 = .gpg/haisa-des.gpg（二进制）"
    elif [ -f "$BS_ROOT/.gpg/haisa-des.pub.asc" ]; then
        gpg --dearmor < "$BS_ROOT/.gpg/haisa-des.pub.asc" > "$gpg_pubkey_bin"
        log "apt: 公钥来源 = .gpg/haisa-des.pub.asc（ASCII→二进制）"
    else
        warn "apt: 无 GPG 公钥（$BS_ROOT/.gpg/haisa-des.{gpg,pub.asc} 都不存在）"
        warn "    设备端 apt update 会因签名验证失败而失败。请先运行 make-keyring.sh init 生成密钥对。"
        warn "    临时降级：在 sources.list 加 [trusted=yes]（不推荐用于生产）"
    fi
    [ -f "$gpg_pubkey_bin" ] && chmod 644 "$gpg_pubkey_bin"

    # apt.conf.d/00-haisa-des: 路径与架构配置（必须最先加载，00 前缀）
    cat > "$etc_apt/apt.conf.d/00-haisa-des" <<EOF
# haisa-des apt 路径配置
# dpkg status 路径（dpkg 的 admindir = $PREFIX/var/lib/dpkg）
Dir::State::status "$PREFIX/var/lib/dpkg/status";
Dir::State::lists "$PREFIX/var/lib/apt/lists";
Dir::State::extended_states "$PREFIX/var/lib/apt/extended_states";
# apt 缓存路径
Dir::Cache::archives "$PREFIX/var/cache/apt/archives";
Dir::Cache::backup "$PREFIX/var/cache/apt/backups";
# apt 配置文件路径
Dir::etc::sourcelist "$PREFIX/etc/apt/sources.list";
Dir::etc::sourceparts "$PREFIX/etc/apt/sources.list.d";
Dir::etc::main "$PREFIX/etc/apt/apt.conf";
Dir::etc::parts "$PREFIX/etc/apt/apt.conf.d";
Dir::etc::preferences "$PREFIX/etc/apt/preferences";
Dir::etc::preferencesparts "$PREFIX/etc/apt/preferences.d";
Dir::etc::trustedparts "$PREFIX/etc/apt/trusted.gpg.d";
# 架构（Debian 用 aarch64，不用 arm64-v8a）
APT::Architecture "aarch64";
APT::Architectures::ArchList "aarch64";
EOF

    # apt.conf.d/99-haisa-des-compressors: 压缩器路径（Termux patch 0004 已硬编码到 $PREFIX/bin）
    # 这里额外配置 zstd 压缩级别等
    cat > "$etc_apt/apt.conf.d/99-haisa-des-compressors" <<'EOF'
# haisa-des: 压缩器配置
# apt 默认用 gzip 压缩 Packages 文件，zstd 压缩 .deb
APT::Compressor::zstd::CompressArg:: "-19";
APT::Compressor::zstd::UncompressArg:: "-d";
EOF

    # ---- apt runtime 目录骨架 ----
    # apt 首次运行（apt update）需要这些目录存在且可写
    # partial 子目录存放下载中的临时文件；缺失会报 "could not create temporary file"
    local var_apt="$PKG_STAGE$PREFIX/var"
    mkdir -p "$var_apt/lib/apt/lists/partial" \
             "$var_apt/lib/apt/lists/auxfiles" \
             "$var_apt/cache/apt/archives/partial" \
             "$var_apt/cache/apt/backups" \
             "$var_apt/lib/dpkg/updates" \
             "$var_apt/log/apt"
    # 占位文件保留空目录（tar 默认不打包空目录，dpkg 卸载时不会清理）
    touch "$var_apt/lib/apt/lists/partial/.keep" \
          "$var_apt/cache/apt/archives/partial/.keep"

    # ---- conffiles 清单 ----
    # 列出受保护的配置文件：升级时若用户修改过则询问保留，否则覆盖
    # mk-deb.sh 读取 staging 内的 .conffiles 文件生成 control/conffiles
    # 注意：trusted.gpg.d/haisa-des.gpg 不在 conffiles 内（密钥轮换时随包更新覆盖）
    cat > "$PKG_STAGE$PREFIX/.conffiles" <<'EOF'
etc/apt/sources.list
etc/apt/apt.conf.d/00-haisa-des
etc/apt/apt.conf.d/99-haisa-des-compressors
EOF

    log "apt: 配置文件已生成到 $etc_apt/"
    log "apt: runtime 目录骨架已生成到 $var_apt/"
}
