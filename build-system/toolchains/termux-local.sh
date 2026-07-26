# 本机 Termux clang 工具链（仅用于本机冒烟，非权威构建）
# 注意：Termux clang 默认把 Termux 自身 prefix 加入搜索路径与 rpath，
# 产物仅用于验证"二进制可在真机执行"，正式发布产物以 CI 的 NDK 构建为准。

TPREFIX="/data/data/com.termux/files/usr"
for t in clang clang++ llvm-ar llvm-ranlib llvm-strip; do
    command -v "$t" >/dev/null 2>&1 || die "缺少 $t（pkg install clang binutils）"
done

# Termux clang 默认 target 为 android24（其基线），需提到 android28 以暴露
# getentropy 等 API 28 声明。注意 --target 必须放 CFLAGS 而非 CC：
# toybox kconfig 等探测会把 CC 整体当命令名，含参数会报 "No ... found"。
export CC="clang"
export CXX="clang++"
export AR="llvm-ar"
export RANLIB="llvm-ranlib"
export STRIP="llvm-strip"
export READELF="llvm-readelf"
export CFLAGS="--target=aarch64-linux-android28 $COMMON_CFLAGS"
export CXXFLAGS="--target=aarch64-linux-android28 $COMMON_CFLAGS"
export LDFLAGS="$COMMON_LDFLAGS"

# Termux 环境下 openssl 走通用 linux 目标（android-arm64 需要 NDK 布局）
export OPENSSL_TARGET="linux-aarch64"

warn "工具链: Termux clang（冒烟专用，产物不可发布）"
$CC --version | head -1
