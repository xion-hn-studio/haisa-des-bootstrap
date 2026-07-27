# python —— CPython 3.13 解释器 + pip（动态交叉编译到 aarch64-linux-android）
PKG_NAME="python"
PKG_VERSION="3.13.14"
PKG_SRC_URL="https://www.python.org/ftp/python/3.13.14/Python-3.13.14.tar.xz"
PKG_SRC_SHA256="639e43243c620a308f968213df9e00f2f8f62332f7adbaa7a7eeb9783057c690"
PKG_SRC_DIR="Python-3.13.14"

pkg_build() {
    local srcdir="$(pwd)"

    # ---- 补丁（sed，幂等）----
    # Android 无 multiarch 目录布局，清空避免 sysconfig 路径错误
    sed -i 's/^MULTIARCH=.*$/MULTIARCH=/' configure.ac configure 2>/dev/null || true

    # ---- 1. 构建宿主 Python（native x86_64，供 --with-build-python 用）----
    # CPython 3.11+ 交叉编译要求 --with-build-python 指向同版本的 native python；
    # 用 out-of-tree build 在 build-host/ 子目录里只构建解释器二进制（make python
    # 不含扩展模块，不依赖宿主的 libssl-dev / libbz2-dev 等开发头文件）。
    # 关键：工具链脚本已把 CC/CXX/CFLAGS/LDFLAGS 设为 aarch64 交叉值，
    # 宿主构建必须覆盖回系统默认编译器（cc/gcc），否则 configure 报
    # "cannot run C compiled programs"（aarch64 二进制无法在 x86_64 执行）。
    local host_build="$srcdir/build-host"
    rm -rf "$host_build"; mkdir -p "$host_build"
    ( cd "$host_build" && \
        CC=cc CXX=c++ CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS= CPPFLAGS= \
        ../configure --without-ensurepip --without-pymalloc \
        && make -j"$JOBS" python )
    local host_python="$host_build/python"
    [ -x "$host_python" ] || die "宿主 Python 构建失败"

    # ---- 2. 交叉配置 ----
    export CPPFLAGS="-I$STAGE_DIR$PREFIX/include -I$STAGE_DIR$PREFIX/include/ncursesw"
    export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"

    local cross_build="$srcdir/build-cross"
    rm -rf "$cross_build"; mkdir -p "$cross_build"
    ( cd "$cross_build" && \
        CONFIG_SITE="$BS_ROOT/packages/python/config.site" \
        ../configure \
            --build="$(sh "$srcdir/config.guess" 2>/dev/null || echo x86_64-pc-linux-gnu)" \
            --host="$TARGET_TRIPLE" \
            --with-build-python="$host_python" \
            --prefix="$PREFIX" \
            --enable-shared \
            --with-system-ffi \
            --with-system-expat \
            --without-ensurepip \
            --with-openssl="$STAGE_DIR$PREFIX" \
            --enable-loadable-sqlite-extensions )

    # ---- 3. 交叉编译 ----
    ( cd "$cross_build" && make -j"$JOBS" )

    # ---- 4. 安装到 staging ----
    # make install 末尾的 compileall 会尝试运行目标 python（aarch64）生成 .pyc，
    # 在 x86_64 宿主上无法执行；.py 文件在此步之前已全部安装，.pyc 可在设备首跑时生成。
    ( cd "$cross_build" && make install DESTDIR="$PKG_STAGE" ) || {
        warn "make install 部分步骤失败（可能是 compileall 交叉运行），检查核心产物..."
        [ -x "$PKG_STAGE$PREFIX/bin/python3.13" ] || die "python3.13 二进制未安装"
        [ -d "$PKG_STAGE$PREFIX/lib/python3.13" ] || die "stdlib 未安装"
    }

    # ---- 5. 手动安装 pip（交叉编译不能用 ensurepip）----
    # CPython 源码树 Lib/ensurepip/_bundled/ 内含 pip wheel，直接解压到 site-packages。
    # 注意：解压需用 zipfile 模块，而 zipfile 依赖 C 扩展 binascii；宿主 python
    # 仅以 `make python` 构建（无 C 扩展），无法 import binascii。改用系统 python3
    # （CI runner / 开发机均预装，含完整 C 扩展）提取 wheel。.whl 本质是 zip，
    # 与解释器版本无关。
    local pyver="python${PKG_VERSION%.*}"   # python3.13
    local pydir="$PKG_STAGE$PREFIX/lib/$pyver"
    mkdir -p "$pydir/site-packages"
    local wheel
    wheel=$(ls "$srcdir/Lib/ensurepip/_bundled/pip-"*.whl 2>/dev/null | head -1)
    [ -n "$wheel" ] || die "未找到 pip wheel"
    python3 -m zipfile -e "$wheel" "$pydir/site-packages/"

    # pip 入口脚本（shebang 指向目标设备上的 python3.13）
    # 1. pip.real：原版 pip 入口（Python 脚本，调 pip._internal.cli.main）
    # 2. pip：haisa-des pip wrapper（bash 脚本，优先查 wheels-index.json，未命中报错）
    # 3. pip3 / pip3.13：符号链接 → pip（统一走 wrapper）
    local pip_bin="$PKG_STAGE$PREFIX/bin"
    local pip_name="pip${PKG_VERSION%.*}"   # pip3.13（去掉末尾 patch 版本号）

    # 1. 原版 pip 入口（直接写成 pip.real，wrapper 透传未拦截命令时调用它）
    cat > "$pip_bin/pip.real" << PIP_EOF
#!$PREFIX/bin/$pyver
import sys
from pip._internal.cli.main import main
if __name__ == '__main__':
    sys.exit(main())
PIP_EOF
    chmod +x "$pip_bin/pip.real"

    # 2. haisa-des pip wrapper（bash 脚本，来自 lib/pip-wrapper.sh）
    #    装包时把 wrapper 脚本一并拷贝到 staging
    if [ -f "$BS_ROOT/lib/pip-wrapper.sh" ]; then
        install -m 755 "$BS_ROOT/lib/pip-wrapper.sh" "$pip_bin/pip"
    else
        warn "  pip wrapper 脚本缺失（lib/pip-wrapper.sh），仅安装原版 pip"
        ln -sf "pip.real" "$pip_bin/pip"
    fi

    # 3. pip3 / pip3.13 → pip（统一走 wrapper）
    ln -sf "pip" "$pip_bin/pip3"
    ln -sf "pip" "$pip_bin/$pip_name"

    # python3 → python3.13（CPython make install 默认会建该链接，但本脚本对
    # make install 做了容错兜底，若 compileall 中断可能缺失。显式补一个确保
    # python3 始终可用，避免设备上 `python3` 找不到。）
    ln -sf "$pyver" "$pip_bin/python3"

    # ---- 6. 校验 C 扩展的 NEEDED 库在 lib/ 均可解析 ----
    # 交叉编译时 C 扩展（lib-dynload/*.so）的 NEEDED 记录的是依赖库的 soname
    # （如 libbz2.so.1.0、libssl.so.3），若打包时只建了 .so / .so.1 链接而漏掉
    # soname 名，设备上 import 会 dlopen 失败。CI 阶段扫描提前暴露此类问题。
    verify_dynload_needed
}

# 扫描 lib-dynload/*.so 的 NEEDED，核对每个由本项目打包的库都能在 $PREFIX/lib 解析。
verify_dynload_needed() {
    # C 扩展在 python 私有 staging（PKG_STAGE），但其依赖库（libssl/libbz2 等）
    # 由其他包提供，已合并到总 STAGE_DIR。必须检查总 STAGE_DIR，否则全部误报缺失。
    local dynload="$PKG_STAGE$PREFIX/lib/python${PKG_VERSION%.*}/lib-dynload"
    local libdir="$STAGE_DIR$PREFIX/lib"
    [ -d "$dynload" ] || { warn "lib-dynload 不存在，跳过 NEEDED 校验"; return; }

    # Bionic 自带系统库（不打包），过滤掉
    local sys_libs='libdl\.so|liblog\.so|libm\.so|libc\.so|libdl|librt|libpthread'

    local missing=0
    local pylibdir="$PKG_STAGE$PREFIX/lib"   # libpython*.so 在此（尚未合并到总 STAGE_DIR）
    while IFS= read -r so; do
        # llvm-readelf -d 输出形如: 0x00000001 (NEEDED) Shared library: [libbz2.so.1.0]
        local needed
        needed=$("$READELF" -d "$so" 2>/dev/null | sed -n 's/.*NEEDED.*\[\([^]]*\)\].*/\1/p')
        for lib in $needed; do
            # 跳过 Bionic 系统库（设备 /system/lib64 提供）
            echo "$lib" | grep -qE "^($sys_libs)" && continue
            # 依赖库可能在总 STAGE_DIR（其他包）或 python 私有 staging（libpython）
            [ -e "$libdir/$lib" ] || [ -e "$pylibdir/$lib" ] || {
                warn "  $(basename "$so") 依赖 $lib，但 $PREFIX/lib/$lib 不存在"
                missing=$((missing + 1))
            }
        done
    done < <(find "$dynload" -name '*.so')

    if [ "$missing" -gt 0 ]; then
        die "发现 $missing 处 NEEDED 库缺失，设备上 import 对应模块会 dlopen 失败"
    fi
    log "  NEEDED 校验通过：lib-dynload/*.so 的依赖库在 lib/ 均可解析"
}
