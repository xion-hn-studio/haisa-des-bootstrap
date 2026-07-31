# gradle —— Gradle 构建工具（纯 Java，依赖 openjdk-17 运行）
#
# 背景:
#   Gradle 是 Android 项目的标准构建工具。用户在设备端编译 Android 项目需要:
#   openjdk-17（JVM 运行时）+ gradle（构建系统）+ Android SDK（aapt2 等）
#
# 实现:
#   Gradle 分发是纯 Java + shell 脚本，无需交叉编译。
#   下载官方 bin.zip，解压到 $PREFIX/lib/gradle/，创建 bin/gradle 入口。
#
# 体积:
#   bin.zip ~134MB（JAR 已 ZIP 压缩，xz 无法进一步压缩）
#   .deb ~134MB > 100MB gh-pages 限制 → STANDALONE，用户从 Releases 手动下载安装:
#     apt install ./gradle_9.6.1_aarch64.deb
#
# 依赖:
#   openjdk-17（gradle 启动脚本通过 JAVA_HOME 找 java，由 openjdk-17 的 profile.d 设置）
PKG_NAME="gradle"
PKG_VERSION="9.6.1"
PKG_SRC_URL="https://services.gradle.org/distributions/gradle-9.6.1-bin.zip"
PKG_SRC_SHA256="9c0f7faeeb306cb14e4279a3e084ca6b596894089a0638e68a07c945a32c9e14"
PKG_SRC_DIR="gradle-9.6.1"
PKG_DESC="Gradle build tool (requires openjdk-17)"

# zip 格式需手动解压（extract_pkg 只支持 tar）
pkg_prepare_src() {
    local zip_file="$CACHE_DIR/${PKG_SRC_URL##*/}"
    local dest="$SRC_DIR/$PKG_SRC_DIR"
    [ -d "$dest" ] && return 0
    mkdir -p "$SRC_DIR"
    local tmp="$SRC_DIR/.extracting-$$"
    rm -rf "$tmp"; mkdir -p "$tmp"
    unzip -q "$zip_file" -d "$tmp" || { rm -rf "$tmp"; die "gradle 解压失败"; }
    [ -d "$tmp/$PKG_SRC_DIR" ] || { rm -rf "$tmp"; die "gradle zip 顶层目录不匹配: 期望 $PKG_SRC_DIR"; }
    mv "$tmp/$PKG_SRC_DIR" "$dest"
    rm -rf "$tmp"
}

pkg_build() {
    local gradle_dir="$PKG_STAGE$PREFIX/lib/gradle"
    install -d -m 755 "$gradle_dir"

    # 拷贝 Gradle 分发内容（已在 SRC_DIR/gradle-9.6.1/ 解压）
    # build.sh 会在 cd "$SRC_DIR/$PKG_SRC_DIR" 后调用 pkg_build
    cp -a ./* "$gradle_dir/"

    # bin/gradle 符号链接（gradle 脚本会解析 symlink 定位 APP_HOME/lib）
    local bin_dir="$PKG_STAGE$PREFIX/bin"
    install -d -m 755 "$bin_dir"
    ln -sf ../lib/gradle/bin/gradle "$bin_dir/gradle"

    # 删除 Windows 批处理文件（Android 无用）
    rm -f "$gradle_dir/bin/gradle.bat"

    # profile.d: 设置 GRADLE_HOME + Android 适配
    local profile_dir="$PKG_STAGE$PREFIX/etc/profile.d"
    install -d -m 755 "$profile_dir"
    cat > "$profile_dir/gradle.sh" <<'PROFEOF'
# Gradle 环境变量
export GRADLE_HOME="$PREFIX/lib/gradle"
export GRADLE_USER_HOME="${HOME:-$PREFIX/home}/.gradle"
# Android 适配: 禁用 daemon（bionic 上进程管理不稳定），指定临时目录
export GRADLE_OPTS="-Dorg.gradle.daemon=false -Djava.io.tmpdir=$PREFIX/tmp ${GRADLE_OPTS:-}"
PROFEOF

    log "gradle: 安装到 $PREFIX/lib/gradle ($(du -sh "$gradle_dir" | awk '{print $1}'))"
}
