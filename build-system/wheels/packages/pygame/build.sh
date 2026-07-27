# pygame —— 图形/游戏库（source 方法交叉编译，依赖 SDL2 系列）
# 依赖 SDL2 系列（sdl2/sdl2_image/sdl2_mixer/sdl2_ttf）已构建进 staging
# CI 需要 setup-qemu-action 注册 binfmt 让 staging 的 aarch64 python3 可在 x86_64 运行
PKG_NAME="pygame"
PKG_VERSION="2.6.0"
PKG_METHOD="source"
# pygame release 只发 wheel 无源码 tarball；CI 主机对 GitHub archive 偶发下载失败，
# 因此把源码 vendor 进仓库 vendor/ 目录，通过 local:// 让 fetch_pkg 从仓库读取。
# 文件名仍保留 2.6.0 + .tar.gz 后缀，保证 ${url##*/} 提取的缓存文件名一致。
PKG_SRC_URL="local://vendor/pygame-2.6.0.tar.gz"
PKG_SRC_SHA256="0dc751d9dc30ba97fa7077d855c1a945fc3ecffcaa90a3a4f3fe4c2b7db3a36a"
PKG_SRC_DIR="pygame-2.6.0"
