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

    # 删除 Windows 批处理文件（Android 无用）
    rm -f "$gradle_dir/bin/gradle.bat"

    # ---- 替换官方 bin/gradle 为简化版 ----
    # 官方启动脚本用 eval+xargs -n1 解析 DEFAULT_JVM_OPTS 的引号参数，
    # 但 Android toybox 的 xargs 对引号处理与 GNU xargs 不同：
    # toybox 保留引号字面字符 → java 收到 main class '"-Xmx64m"' → ClassNotFoundException。
    # 这里用简化脚本直接调用 java，绕过 eval+xargs 兼容性问题。
    local cli_jar
    cli_jar=$(ls "$gradle_dir/lib/gradle-gradle-cli-main-"*.jar 2>/dev/null | head -1)
    [ -n "$cli_jar" ] || { warn "gradle: 未找到 cli-main jar"; return 1; }
    cli_jar=${cli_jar##*/}  # 只取文件名，运行时拼接路径

    cat > "$gradle_dir/bin/gradle" <<GRADLEOF
#!/bin/sh
# haisa-des 简化版 gradle 启动脚本（绕过官方 eval+xargs 在 toybox 上的引号 bug）
# 原理: 直接用 -jar 调用 gradle-cli-main，JVM 参数手动拼接（不依赖 xargs 解析引号）
#
# 注意: make-bootstrap 会把 bin/gradle 符号链接替换为实体文件拷贝，
# 所以不能用 \$0 推导 APP_HOME（\$0 指向 \$PREFIX/bin/gradle，但 gradle
# lib 在 \$PREFIX/lib/gradle/）。改用 GRADLE_HOME 环境变量定位 gradle 安装目录。
set -e

# GRADLE_HOME: 优先环境变量（profile.d 设置），否则固定路径 fallback
GRADLE_HOME="\${GRADLE_HOME:-}"
if [ -z "\$GRADLE_HOME" ]; then
    GRADLE_HOME="\${PREFIX:-/data/data/com.haisades/files/usr}/lib/gradle"
fi
[ -d "\$GRADLE_HOME/lib" ] || { echo "gradle: 找不到 gradle 安装目录: \$GRADLE_HOME" >&2; exit 1; }

# JAVA_HOME: 优先环境变量，否则从 openjdk-17 profile.d 设置的路径找
JAVA_HOME="\${JAVA_HOME:-}"
if [ -z "\$JAVA_HOME" ]; then
    # openjdk-17 安装在 \$PREFIX/lib/jvm/java-17-openjdk
    JAVA_HOME="\${PREFIX:-/data/data/com.haisades/files/usr}/lib/jvm/java-17-openjdk"
fi
JAVACMD="\$JAVA_HOME/bin/java"
[ -x "\$JAVACMD" ] || { echo "gradle: 找不到 java: \$JAVACMD" >&2; exit 1; }

# Gradle 9.x 需要 instrumentation agent（构建性能监控，可选但官方默认启用）
AGENT_JAR="\$GRADLE_HOME/lib/agents/gradle-instrumentation-agent-9.6.1.jar"

# JVM 参数（与官方 DEFAULT_JVM_OPTS 一致，但直接展开，避免引号解析问题）
JVM_OPTS="-Xmx64m -Xms64m"
[ -f "\$AGENT_JAR" ] && JVM_OPTS="\$JVM_OPTS -javaagent:\$AGENT_JAR"

# 用户自定义参数（JAVA_OPTS / GRADLE_OPTS，按空格分词）
JVM_OPTS="\$JVM_OPTS \${JAVA_OPTS:-} \${GRADLE_OPTS:-}"

# 执行: java <jvm opts> -Dorg.gradle.appname=gradle -jar <cli-main.jar> <args>
exec "\$JAVACMD" \$JVM_OPTS \\
    "-Dorg.gradle.appname=gradle" \\
    -jar "\$GRADLE_HOME/lib/${cli_jar}" \\
    "\$@"
GRADLEOF
    chmod 755 "$gradle_dir/bin/gradle"

    # bin/gradle 符号链接（指向 lib/gradle/bin/gradle）
    local bin_dir="$PKG_STAGE$PREFIX/bin"
    install -d -m 755 "$bin_dir"
    ln -sf ../lib/gradle/bin/gradle "$bin_dir/gradle"

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
    log "gradle: 替换为简化启动脚本（绕过 toybox xargs 引号 bug）"
}
