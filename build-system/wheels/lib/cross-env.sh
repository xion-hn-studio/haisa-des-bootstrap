# HaisaDes wheel 交叉编译环境（B4 阶段 pygame 等源码 wheel 用）
# 本文件由 build-wheels.sh 在 source 方法时 source。
# 前置条件：build-system 已完成 build all，staging 内有完整的 $PREFIX/bin/python3
#          与 SDL2 系列 .so。CI 需 setup-qemu-action 注册 binfmt 让 aarch64 ELF 可在 x86_64 上运行。

# 让 CPython 把目标平台标记为 linux-aarch64（pip wheel 命名规则依据）
export _PYTHON_HOST_PLATFORM="linux-aarch64"
# 跨平台 sysroot 路径：让 setuptools 在编译 C 扩展时找到 staging 的头文件与库
export SYSROOT="$STAGE_DIR"
# pkg-config 指向 staging（SDL2/freetype 等的 .pc 在此）
export PKG_CONFIG_PATH="$STAGE_DIR$PREFIX/lib/pkgconfig"
# 让 sdists 构建时优先用 staging 的 sdl2-config 等
export PATH="$STAGE_DIR$PREFIX/bin:$PATH"
# 运行 aarch64 Python 解释器时让扩展 .so 能找到 staging 的 .so
export LD_LIBRARY_PATH="$STAGE_DIR$PREFIX/lib"
# wheel 标签：CPython 3.13 = cp313
export WHEEL_PY_TAG="${WHEEL_PY_TAG:-cp313}"
