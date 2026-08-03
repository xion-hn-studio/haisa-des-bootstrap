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

    # ---- 交叉编译 native-platform .so（Android bionic 兼容）----
    # Gradle 的 libnative-platform.so 是为标准 Linux (glibc) 编译的，依赖
    # GLIBC_2.17 版本符号和 libstdc++.so.6，Android bionic 不提供，导致
    # gradle 报 "Failed to load native library 'libnative-platform.so'"。
    # 这里用 NDK clang++ 重新编译 native-platform C++ 源码，生成 bionic 兼容的 .so，
    # 替换 native-platform-linux-aarch64-*.jar 里的 .so。
    # native-platform .so 替换失败 → 不打 gradle .deb（避免设备端加载旧 .so 仍报错）
    if ! _build_native_platform "$gradle_dir"; then
        warn "gradle: native-platform .so 替换失败，跳过 gradle 打包（不生成 .deb）"
        return 1
    fi

    log "gradle: 安装到 $PREFIX/lib/gradle ($(du -sh "$gradle_dir" | awk '{print $1}'))"
    log "gradle: 简化启动脚本（绕过 toybox xargs 引号 bug）+ native-platform .so 交叉编译完成"
}

# 交叉编译 native-platform .so 并替换 jar 里的原始 .so
# 参数: $1 = gradle 安装目录（$PREFIX/lib/gradle）
# 失败时返回 1（调用方应跳过 gradle .deb，避免设备端加载旧 .so 仍报错）
_build_native_platform() {
    local gradle_dir="$1"

    # native-platform-linux-aarch64-*.jar: 含待替换的 libnative-platform.so
    local np_jar
    np_jar=$(ls "$gradle_dir/lib/native-platform-linux-aarch64-"*.jar 2>/dev/null | grep -v ncurses | head -1)
    [ -n "$np_jar" ] || { warn "gradle: 未找到 native-platform-linux-aarch64 jar，无法替换 .so"; return 1; }

    # native-platform-<ver>.jar（主 jar）: 含全部已编译 Java class，用作 javac classpath。
    #   JNI 源码 import 了 net.rubygrapefruit.platform.internal.FileSystemList / FunctionResult
    #   等类（不在 internal/jni 包内），必须用主 jar 才能解析全部符号，否则 javac 失败、
    #   头文件不生成、.so 编译失败，最终设备端仍加载旧 .so。
    local np_main_jar
    np_main_jar=$(ls "$gradle_dir/lib/native-platform-"*.jar 2>/dev/null | grep -v -E 'linux-aarch64|ncurses' | head -1)
    [ -n "$np_main_jar" ] || { warn "gradle: 未找到 native-platform 主 jar（classpath），无法生成 JNI 头文件"; return 1; }

    local np_src_dir="$SRC_DIR/native-platform-src"
    local np_build="$WORK_DIR/native-platform-build"
    rm -rf "$np_build"; mkdir -p "$np_build"
    local np_cpp_dir="$np_src_dir/native-platform"

    # 1. 下载 native-platform 源码（如未下载）
    if [ ! -d "$np_cpp_dir" ]; then
        log "gradle: 下载 native-platform 源码..."
        git clone --depth 1 https://github.com/gradle/native-platform.git "$np_src_dir" 2>&1 | tail -2
    fi
    [ -d "$np_cpp_dir" ] || { warn "gradle: native-platform 源码下载失败"; return 1; }

    # 2. 用 javac -h 生成 JNI 头文件（classpath = 主 jar，解析全部依赖符号）
    #    这保证 JNI 函数签名与 gradle 实际使用的 class 完全匹配
    log "gradle: 生成 JNI 头文件 (javac -h, classpath=$(basename "$np_main_jar"))..."
    local jni_dir="$np_build/jni-headers"
    mkdir -p "$jni_dir"
    local javac_cmd="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}/bin/javac"
    [ -x "$javac_cmd" ] || javac_cmd="javac"
    "$javac_cmd" -h "$jni_dir" \
        -cp "$np_main_jar" \
        -d "$np_build/classes" \
        "$np_cpp_dir/src/main/java/net/rubygrapefruit/platform/internal/jni/"*.java 2>&1 | tail -10 || true
    local np_header="$jni_dir/net_rubygrapefruit_platform_internal_jni_PosixFileSystemFunctions.h"
    [ -f "$np_header" ] || { warn "gradle: JNI 头文件生成失败（$np_header 不存在）"; return 1; }

    # 3. patch linux.cpp: Android bionic 无 <mntent.h>，改用 /proc/mounts
    local linux_cpp="$np_build/linux.cpp"
    {
        echo '/*'
        echo ' * Android bionic 兼容版 linux.cpp'
        echo ' * 原始代码用 <mntent.h>（setmntent/getmntent_r），bionic 不提供，'
        echo ' * 改用 fopen 读 /proc/mounts + fscanf 解析。'
        echo ' */'
        echo '#ifdef __linux__'
        echo ''
        echo '#include "generic.h"'
        echo '#include "net_rubygrapefruit_platform_internal_jni_PosixFileSystemFunctions.h"'
        echo '#include <stdio.h>'
        echo '#include <stdlib.h>'
        echo '#include <sys/inotify.h>'
        echo '#include <unistd.h>'
        echo ''
        echo 'JNIEXPORT void JNICALL'
        echo 'Java_net_rubygrapefruit_platform_internal_jni_PosixFileSystemFunctions_listFileSystems(JNIEnv* env, jclass target, jobject info, jobject result) {'
        echo '    FILE* fp = fopen("/proc/mounts", "r");'
        echo '    if (fp == NULL) {'
        echo '        mark_failed_with_errno(env, "could not open /proc/mounts", result);'
        echo '        return;'
        echo '    }'
        echo '    jclass info_class = env->GetObjectClass(info);'
        echo '    jmethodID method = env->GetMethodID(info_class, "add", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZZZ)V");'
        echo '    char device[256], mount_dir[512], fs_type[64], options[256];'
        echo '    int dump, pass;'
        echo '    while (fscanf(fp, "%255s %511s %63s %255s %d %d",'
        echo '                   device, mount_dir, fs_type, options, &dump, &pass) == 6) {'
        echo '        jstring mount_point = char_to_java(env, mount_dir, result);'
        echo '        jstring file_system_type = char_to_java(env, fs_type, result);'
        echo '        jstring device_name = char_to_java(env, device, result);'
        echo '        env->CallVoidMethod(info, method, mount_point, file_system_type, device_name, JNI_FALSE, JNI_TRUE, JNI_TRUE);'
        echo '    }'
        echo '    fclose(fp);'
        echo '}'
        echo ''
        echo '#endif'
    } > "$linux_cpp"

    # 4a. 生成 native_platform_version.h（上游构建系统生成，仓库未提交）
    #     generic.h include 它，generic.cpp 用 NATIVE_VERSION 宏（NativeLibraryFunctions.getVersion() 返回值）。
    #     从主 jar 文件名提取 native-platform 版本号（如 native-platform-0.22-milestone-29.jar → 0.22-milestone-29）。
    local gen_inc="$np_build/gen-headers"
    mkdir -p "$gen_inc"
    local np_version
    np_version=$(basename "$np_main_jar" | sed -E 's/^native-platform-//; s/\.jar$//')
    cat > "$gen_inc/native_platform_version.h" <<VEREOF
#ifndef NATIVE_PLATFORM_VERSION_H
#define NATIVE_PLATFORM_VERSION_H
#define NATIVE_VERSION "${np_version}"
#endif
VEREOF

    # 4b. 用 NDK clang++ 编译（链接 bionic libc，非 glibc）
    log "gradle: 交叉编译 libnative-platform.so (NDK clang++)..."
    local np_inc="-I$np_cpp_dir/src/shared/headers -I$jni_dir -I$gen_inc"
    local np_srcs="$linux_cpp \
        $np_cpp_dir/src/main/cpp/posix.cpp \
        $np_cpp_dir/src/shared/cpp/generic.cpp \
        $np_cpp_dir/src/shared/cpp/generic_posix.cpp \
        $np_cpp_dir/src/shared/cpp/unix_strings.cpp"
    "$CXX" -shared -fPIC $CXXFLAGS $np_inc $np_srcs \
        -o "$np_build/libnative-platform.so" $LDFLAGS 2>&1 | tail -10 || true
    [ -f "$np_build/libnative-platform.so" ] || { warn "gradle: libnative-platform.so 编译失败"; return 1; }
    "$STRIP" "$np_build/libnative-platform.so" 2>/dev/null || true
    log "gradle: 编译成功 $(du -h "$np_build/libnative-platform.so" | awk '{print $1}')"

    # 5. 替换 native-platform-linux-aarch64-*.jar 里的 .so
    #    jar 里的路径: net/rubygrapefruit/platform/linux-aarch64/libnative-platform.so
    log "gradle: 替换 $(basename "$np_jar") 里的 libnative-platform.so..."
    local jar_cmd="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}/bin/jar"
    [ -x "$jar_cmd" ] || jar_cmd="jar"
    ( cd "$np_build" && \
      mkdir -p net/rubygrapefruit/platform/linux-aarch64 && \
      cp libnative-platform.so net/rubygrapefruit/platform/linux-aarch64/ && \
      "$jar_cmd" uf "$np_jar" net/rubygrapefruit/platform/linux-aarch64/libnative-platform.so 2>&1 | tail -3 ) \
      || { warn "gradle: jar 更新失败（.so 未替换）"; return 1; }
    log "gradle: native-platform .so 替换完成"
}
