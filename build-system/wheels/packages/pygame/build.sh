# pygame —— 图形/游戏库（download 方法，从 PyPI 拉 cp313 aarch64 manylinux wheel）
# pygame 2.6.1 起 PyPI 官方发布 cp313 aarch64 manylinux wheel，可直接 download，
# 无需 source 交叉编译（避开 QEMU binfmt 无法运行 Android 动态链接 python3 的限制）。
# manylinux aarch64 wheel 在 Android bionic 上可运行（C 扩展仅用标准 libc API，
# bionic 兼容 manylinux 符号集；与 numpy/Pillow/lxml 同机制）。
PKG_NAME="pygame"
PKG_VERSION="2.6.1"
PKG_METHOD="download"
PKG_PY_TAG="cp313"
