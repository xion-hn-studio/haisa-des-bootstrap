# haisa-des 交叉编译踩坑记录

> 本文档记录把 haisa-des 从"bash 脚本模拟包管理"升级到"真 Debian apt + dpkg"过程中遇到的所有编译坑及最终解决方案。后续维护者遇到类似问题可在此对号入座，避免重复踩坑。

## 背景与构建流程

- **目标平台**：aarch64-linux-android（Android arm64-v8a）
- **CI 主机**：x86_64 Linux（GitHub Actions runner）
- **构建方式**：交叉编译（`TOOLCHAIN=ndk`，使用 NDK r29 工具链）
- **包格式**：Debian `.deb`（ar 归档：debian-binary + control.tar.gz + data.tar.gz）
- **仓库元数据**：Debian 标准结构（`dists/stable/main/binary-aarch64/Packages[.gz]` + `Release` + `InRelease` GPG 签名）
- **当前包清单（33 个，按构建顺序）**：
  ```
  zlib ncurses bash openssl ca-certificates curl toybox
  libffi sqlite bzip2 xz expat readline
  liblz4 zstd xxhash libiconv
  libgpg-error libgcrypt
  gmp nettle libtasn1 p11-kit libunistring libidn2 libgnutls
  libpng libjpeg-turbo freetype sdl2 sdl2_image sdl2_mixer sdl2_ttf
  python libmd dpkg apt
  ```

### 关键路径约定

构建系统通过环境变量管理"设备路径"与"CI 主机路径"的映射：

| 变量 | 含义 | 示例 |
|------|------|------|
| `$PREFIX` | 设备端安装前缀（设备路径） | `/data/data/com.haisades/files/usr` |
| `$STAGE_DIR` | 总 staging 目录（CI 主机路径，merge_stage 后所有包汇总于此） | `/workspace/haisa-des-bootstrap/build-system/dist/stage` |
| `$PKG_STAGE` | 当前包私有 staging（stage_install 落地处） | `dist/per-pkg-stage/nettle` |

**核心难点**：`$STAGE_DIR$PREFIX/lib` 包含 `$PREFIX/lib` 作为子串。任何"把设备路径替换为 staging 路径"的操作都要小心**双重前缀**问题（详见 [坑 5](#坑-5libtool-la-文件路径硬编码双重前缀)）。

---

## 坑 1：libgpg-error 的 perl 脚本 shebang

**包**：libgpg-error 1.51
**依赖位置**：libgcrypt 链的根
**对应文件**：[packages/libgpg-error/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/libgpg-error/build.sh)

### 现象

libgpg-error 本身编译通过。下游 libgcrypt configure 时调用 `gpg-error-config` 脚本取 cflags/libs，报：
```
/bin/sh: 1: /data/data/com.termux/files/usr/bin/perl: not found
```
或者 CI 主机上：
```
/usr/bin/perl: bad interpreter: No such file or directory
```

### 根因

上游 `bin/gpg-error-config` 是 perl 脚本，shebang 在 `make install` 时被 patch 成安装时的 perl 路径。交叉编译时这个路径是**设备路径**（`/data/data/com.termux/files/usr/bin/perl`）或 CI host 的 perl 路径——无论哪个，下游包 configure 在 CI 主机执行时都找不到该 perl。

### 解决

在 `stage_install` 后用 POSIX sh wrapper 替换 perl 脚本（[build.sh:46-62](file:///workspace/haisa-des-bootstrap/build-system/packages/libgpg-error/build.sh#L46-L62)）：

```bash
local bindir="$PKG_STAGE$PREFIX/bin"
local stage_prefix="$STAGE_DIR$PREFIX"
cat > "$bindir/gpg-error-config" <<EOF
#!/bin/sh
case "\$1" in
    --version) echo "$PKG_VERSION" ;;
    --cflags)  echo "-I$stage_prefix/include" ;;
    --libs)    echo "-L$stage_prefix/lib -lgpg-error" ;;
    --prefix)  echo "$stage_prefix" ;;
    --host)    echo "aarch64-unknown-linux-android" ;;
    *)         echo "-I$stage_prefix/include -L$stage_prefix/lib -lgpg-error" ;;
esac
EOF
chmod 755 "$bindir/gpg-error-config"
```

**关键点**：路径写死为 `$STAGE_DIR$PREFIX`（CI 主机能访问的 staging 路径），merge_stage 后下游从 `$STAGE_DIR$PREFIX/bin/` 调用，路径有效。不依赖 perl，跨 host 一致可执行。

### 同类问题预防

任何包安装的 `*-config` 脚本如果是 perl/python 实现，且被下游包 configure 调用，都需要替换为 sh wrapper 或硬编码路径版本。

---

## 坑 2：p11-kit 找不到 libffi 头文件

**包**：p11-kit 0.25.5
**依赖位置**：libgnutls 链
**对应文件**：[packages/p11-kit/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/p11-kit/build.sh)

### 现象

```
p11-kit/virtual.c:74:10: fatal error: 'ffi.h' file not found
```

### 根因

p11-kit 的 `virtual.c` 用 `#include "ffi.h"`（双引号，先搜源码目录再搜 `-I` 路径）。configure 用 `AC_CHECK_LIB([ffi], [ffi_call])` 探测到 libffi 存在（因为 LDFLAGS 含 staging 路径），但 CFLAGS 没传 staging include，编译时找不到 `ffi.h`。

### 解决

显式设置 `FFI_CFLAGS` 和 `FFI_LIBS`，**同时**加到 CFLAGS/LDFLAGS 兜底（[build.sh:12-19](file:///workspace/haisa-des-bootstrap/build-system/packages/p11-kit/build.sh#L12-L19)）：

```bash
export FFI_CFLAGS="-I$STAGE_DIR$PREFIX/include"
export FFI_LIBS="-L$STAGE_DIR$PREFIX/lib -lffi"
# 备用：直接加到 CFLAGS/LDFLAGS 兜底（p11-kit 0.25 configure 不一定用 FFI_CFLAGS）
export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
```

### 通用规律

交叉编译时，**configure 探测（`AC_CHECK_LIB`）用 LDFLAGS，编译用 CFLAGS**，两者必须都设。单设一个会出现"configure 通过但 make 编译失败"的诡异现象。对 `<dep>_CFLAGS`/`<dep>_LIBS` 形式的环境变量，**建议同时加到 CFLAGS/LDFLAGS 兜底**，因为不是所有 configure 都严格遵守 pkg-config 风格变量。

---

## 坑 3：libidn2 找不到 libunistring

**包**：libidn2 2.3.7
**依赖位置**：libgnutls 链
**对应文件**：[packages/libidn2/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/libidn2/build.sh)

### 现象

```
configure: error: Libunistring was not found
```
即使设置了 `LIBUNISTRING_CFLAGS`/`LIBUNISTRING_LIBS` 指向 staging 的 libunistring 仍然失败。

### 根因

libidn2 用 gnulib 的 `AM_LIB_UNISTRING` 宏检测 libunistring，这个宏在交叉编译时**会尝试运行 test program** 检测 `u8_normalize` 等函数存在性。aarch64 二进制无法在 x86_64 host 执行 → 检测失败 → 报错。`LIBUNISTRING_CFLAGS`/`LIBUNISTRING_LIBS` 只影响链接，不影响函数存在性检测。

### 解决

用 `--with-included-unistring` 让 libidn2 用源码自带的 libunistring 副本（[build.sh:14-18](file:///workspace/haisa-des-bootstrap/build-system/packages/libidn2/build.sh#L14-L18)）：

```bash
gnu_configure \
    --with-included-unistring \
    --disable-doc \
    --disable-tests \
    --disable-rpath
```

**说明**：libunistring 副本静态链接进 libidn2.so，不产生独立 libunistring.so 冗余。设备端运行时无差异（libidn2 已包含所需符号）。

### 通用规律

**凡是 gnulib 模块（`AM_LIB_*`）的依赖检测，交叉编译时几乎都会因"无法运行 test program"失败**。解决方案优先级：
1. `--with-included-<dep>`（用源码自带副本，最省事）
2. `ac_cv_lib_<dep>_<func>=yes` cache 变量（绕过检测，详见 [坑 7](#坑-7libgnutls-函数检测失败cache-变量绕过)）
3. patch configure 跳过检测（最后手段）

---

## 坑 4：nettle 找不到 GMP 导致 libhogweed 未构建

**包**：nettle 3.10
**依赖位置**：libgnutls 链
**对应文件**：[packages/nettle/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/nettle/build.sh)

### 现象

nettle 本身编译通过，但下游 libgnutls 链接时报：
```
ld.lld: error: unable to find library -lhogweed
```
检查 staging 发现 `libnettle.so` 存在但 `libhogweed.so` 缺失。

### 根因

nettle 的 `libhogweed`（公钥算法库）依赖 GMP。configure 检测 GMP 时如果找不到，会输出 warning：
```
Support for public key algorithms will be unavailable
```
然后**静默跳过 libhogweed 构建**（不报错，只 warning）。下游 libgnutls 链接 `-lhogweed` 时才发现库不存在。

### 解决

在 nettle 的 build.sh 里显式把 GMP 的 staging 路径加到 CFLAGS/LDFLAGS（[build.sh:13-14](file:///workspace/haisa-des-bootstrap/build-system/packages/nettle/build.sh#L13-L14)）：

```bash
export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
```

同时 `--disable-assembler`（Termux 环境缺 m4/as 汇编器，禁用汇编避免探测失败）。

### 通用规律

**nettle 的 GMP 检测失败是"静默降级"而非"硬错误"**——这是最坑的类型，因为编译看似成功，实则产物残缺。**任何依赖 nettle 的库（libgnutls/libhogweed）必须在编译后检查 `libhogweed.so` 是否生成**。遇到 `-lhogweed not found` 时，第一时间查 nettle 的 configure 输出有没有 "public key algorithms unavailable" warning。

---

## 坑 5：libtool .la 文件路径硬编码（双重前缀）

**影响包**：所有用 autotools + libtool 的包
**对应文件**：[lib/common.sh](file:///workspace/haisa-des-bootstrap/build-system/lib/common.sh) 的 `fix_la_paths` 函数

### 现象

下游包 libtool 链接时报：
```
libtool: error: '/data/data/com.haisades/files/usr/lib/libffi.la' is not a valid libtool archive
```
或：
```
libtool: error: '/workspace/.../stage/data/data/com.haisades/files/usr/lib/libffi.la' is not a valid libtool archive
```

### 根因

libtool 在 `make install` 时生成的 `.la` 文件里，`libdir` 字段记录的是**设备路径** `$PREFIX/lib`（即 `--prefix` 指定的值），或 **per-pkg-stage 路径** `$PKG_STAGE$PREFIX/lib`（libtool `--mode=install` 写入的 install 目标）。

下游包 libtool 链接时会读 `.la` 文件的 `dependency_libs` 找依赖库路径。CI 主机上设备路径不存在 → "not a valid libtool archive"。

### 解决：sentinel 三步替换法

在 [common.sh](file:///workspace/haisa-des-bootstrap/build-system/lib/common.sh#L97-L129) 的 `fix_la_paths` 函数中，**关键难点**是路径嵌套：

```
$stage_libdir    = $STAGE_DIR + $PREFIX/lib
$dev_libdir      = $PREFIX/lib
$pkg_stage_libdir = $PKG_STAGE + $PREFIX/lib
```

`$stage_libdir` 包含 `$dev_libdir` 作为子串。直接 `s{$dev_libdir}{$stage_libdir}g` 会把 `$stage_libdir` 内的 `$dev_libdir` 也替换 → `$STAGE_DIR$STAGE_DIR$PREFIX/lib` 双重前缀。

**sentinel 三步替换**避免双重前缀：

```bash
fix_la_paths() {
    local la stage_libdir dev_libdir pkg_stage_libdir sentinel
    dev_libdir="$PREFIX/lib"
    stage_libdir="$STAGE_DIR$PREFIX/lib"
    pkg_stage_libdir="$PKG_STAGE$PREFIX/lib"
    sentinel="__HAISA_LIBDIR_SENTINEL_5F8A3B__"
    for la in "$PKG_STAGE$PREFIX"/lib/*.la; do
        [ -f "$la" ] || continue
        # libdir='...' 行：强制改为 stage_libdir（不论原值）
        sed -i "s|^libdir='[^']*'|libdir='$stage_libdir'|" "$la"
        # dependency_libs 里的路径：sentinel 三步替换避免双重前缀
        perl -i -pe "s{\\Q$stage_libdir\\E}{$sentinel}g" "$la"
        perl -i -pe "s{\\Q$pkg_stage_libdir\\E}{$sentinel}g" "$la"
        perl -i -pe "s{\\Q$dev_libdir\\E}{$stage_libdir}g" "$la"
        perl -i -pe "s{\\Q$sentinel\\E}{$stage_libdir}g" "$la"
    done
}
```

**调用时机**：在 `build.sh` 的 `build_one` 里，`pkg_build` 之后、`merge_stage` 之前调用（[build.sh:116-118](file:///workspace/haisa-des-bootstrap/build-system/build.sh#L116-L118)）：

```bash
( cd "$SRC_DIR/$PKG_SRC_DIR" && pkg_build )
fix_la_paths
merge_stage "$name"
```

### 为什么不用 perl 负向后行断言？

第一版尝试用 `perl -i -pe "s{(?<!\\Q$STAGE_DIR\\E)\\Q$dev_libdir\\E}{$stage_libdir}g"`，但：
1. 负向后行断言要求断言部分固定长度，`$STAGE_DIR` 长度可变
2. 无法处理 `$pkg_stage_libdir`（per-pkg-stage 路径）的情况

sentinel 三步替换更通用、更可靠。

### 通用规律

**所有 autotools + libtool 包都会生成 .la 文件**。fix_la_paths 是通用兜底，不需要每个包单独处理。但如果某个包的 `.la` 文件路径异常，检查 `libdir=` 行是否被正确改写。

---

## 坑 6：libgnutls p11-kit 头文件路径

**包**：libgnutls 3.8.9
**依赖位置**：TLS 链终点
**对应文件**：[packages/libgnutls/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/libgnutls/build.sh)

### 现象

```
configure: error: p11-kit/pkcs11.h is required
```
或编译时：
```
fatal error: 'p11-kit/pkcs11.h' file not found
```

### 根因

p11-kit 头文件安装在 `$PREFIX/include/p11-kit-1/p11-kit/`（多一层 `p11-kit-1` 目录）。libgnutls 用 `#include <p11-kit/pkcs11.h>`，需要 `-I` 指向 `p11-kit-1` 目录。

pkg-config 返回的 cflags 是设备路径 `$PREFIX/include/p11-kit-1`，CI 主机找不到。

### 解决

显式设置 `P11_KIT_CFLAGS` 指向 staging 的 `p11-kit-1` 子目录（[build.sh:23](file:///workspace/haisa-des-bootstrap/build-system/packages/libgnutls/build.sh#L23)）：

```bash
# p11-kit 头文件装在 $PREFIX/include/p11-kit-1/p11-kit/
export P11_KIT_CFLAGS="-I$STAGE_DIR$PREFIX/include/p11-kit-1"
export P11_KIT_LIBS="-L$STAGE_DIR$PREFIX/lib -lp11-kit"
```

### 通用规律

**头文件安装在子目录的库**（如 p11-kit 的 `p11-kit-1`、SDL2 的 `SDL2`、ncurses 的 `ncursesw`）需要 `-I` 指向**包含子目录的父目录**，而非库的 install prefix。交叉编译时 pkg-config 返回的 cflags 是设备路径，必须手动覆盖为 staging 路径。

---

## 坑 7：libgnutls 函数检测失败（cache 变量绕过）

**包**：libgnutls 3.8.9
**对应文件**：[packages/libgnutls/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/libgnutls/build.sh)

### 现象

```
configure: error: Nettle lacks the required rsa_sec_decrypt function
```
或：
```
configure: error: cannot find nettle_get_secp_192r1 in -lhogweed
```

### 根因

libgnutls 的 configure 用 `AC_CHECK_FUNCS` 和 `AC_CHECK_LIB` 检测 nettle 的某些函数。这些宏在交叉编译时**会尝试编译并运行 test program** 来验证符号存在性。aarch64 二进制无法在 x86_64 host 执行 → 宏返回 no → configure 报错。

但实际上 nettle 3.10 **确实有这些符号**（只是函数名加了 `nettle_` 前缀，如 `nettle_rsa_sec_decrypt`）。

### 解决

用 autotools 的 cache 变量绕过运行时检测（[build.sh:32-35](file:///workspace/haisa-des-bootstrap/build-system/packages/libgnutls/build.sh#L32-L35)）：

```bash
# AC_CHECK_FUNCS 在交叉编译时无法运行 test program 检测符号存在性
export ac_cv_func_nettle_rsa_sec_decrypt=yes
export ac_cv_func_nettle_rsa_oaep_sha256_encrypt=yes
# AC_CHECK_LIB(hogweed, nettle_get_secp_192r1) 同问题
export ac_cv_lib_hogweed_nettle_get_secp_192r1=yes
```

### 通用规律

autotools 的 `AC_CHECK_FUNCS(func)` 对应 cache 变量 `ac_cv_func_<func>`，`AC_CHECK_LIB(lib, func)` 对应 `ac_cv_lib_<lib>_<func>`。交叉编译时设为 `yes` 可绕过运行时检测。

**命名规则**：
- 函数名中的非字母数字字符替换为下划线
- 库名同样处理
- 例如 `AC_CHECK_LIB([hogweed], [nettle_get_secp_192r1])` → `ac_cv_lib_hogweed_nettle_get_secp_192r1`

**使用前必须确认符号确实存在**（查上游头文档或 `nm` 检查），否则会编出残缺产物。

---

## 坑 8：dpkg md5 digest 检测失败（缺少 libmd）

**包**：dpkg 1.22.22
**对应文件**：[packages/dpkg/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh) + [packages/libmd/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/libmd/build.sh)

### 现象

```
configure: error: md5 digest functions not found
```

### 根因

dpkg 的 configure 用 `AC_CHECK_LIB([md], [MD5Init])` 探测 BSD 风格的 MD5 函数（`MD5Init`/`MD5Update`/`MD5Final`）。这些符号来自 **libmd**（BSD message digest 库）。

**Android bionic libc 不导出这些符号**——bionic 只有 OpenSSL 风格的 `MD5_Init`（带下划线），dpkg 拒绝使用 OpenSSL API。所以必须提供 libmd。

### 解决

新增 libmd 包（[packages/libmd/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/libmd/build.sh)）：

```bash
PKG_NAME="libmd"
PKG_VERSION="1.1.0"
PKG_SRC_URL="https://deb.debian.org/debian/pool/main/libm/libmd/libmd_1.1.0.orig.tar.xz"
PKG_SRC_SHA256="1bd6aa42275313af3141c7cf2e5b964e8b1fd488025caf2f971f43b00776b332"
PKG_SRC_DIR="libmd-1.1.0"

pkg_build() {
    gnu_configure
    make -j"$JOBS"
    stage_install
}
```

在 [build.sh](file:///workspace/haisa-des-bootstrap/build-system/build.sh) 的 ALL_PACKAGES 里加 `libmd`（在 dpkg 之前），并把 dpkg 的依赖改为 `libmd`：

```bash
# dpkg：静态库；依赖 libmd（BSD 风格 MD5Init/MD5Update/MD5Final）
dpkg)            echo "libmd" ;;
```

dpkg 的 build.sh 显式指向 staging 的 libmd（[build.sh:46-49](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh#L46-L49)）：

```bash
export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
export LIBS="-lmd"
```

### 通用规律

**BSD 风格 API vs OpenSSL 风格 API** 是 Android 交叉编译的常见坑。许多 GNU/Debian 软件假设 libc 提供 BSD 风格的 MD5/SHA 函数，但 bionic 不提供。需要引入 libmd（BSD 兼容包装）或 patch 软件改用 OpenSSL API。

类似的"libc 不提供"的符号还有：`glob()`（Android 7 之前无，需 libandroid-glob）、`pthread_cancel`（bionic 无，需 `-Dpthread_cancel=0` 绕过，见 [libgpg-error build.sh:31](file:///workspace/haisa-des-bootstrap/build-system/packages/libgpg-error/build.sh#L31)）。

---

## 坑 8.5：新增包忘记加 pkg_deps 分支（未知包: libmd）

**包**：libmd（新增包时易犯）
**对应文件**：[build.sh](file:///workspace/haisa-des-bootstrap/build-system/build.sh) 的 `pkg_deps` 函数

### 现象

```
[build] libmd: 合并到总 staging
[error] 未知包: libmd
```
libmd 编译成功并 merge_stage 完成，但 build.sh 报"未知包"退出。

### 根因

`build.sh` 的 `pkg_deps()` 函数用 `case` 语句硬编码每个包的依赖。新增包 `libmd` 时只加到了 `ALL_PACKAGES` 列表和 `packages/libmd/build.sh`，但**忘记在 `pkg_deps` 函数里加 `libmd) echo "" ;;` 分支**。`expand_with_deps` 调用 `pkg_deps libmd` 时走到 `*) die "未知包: $1" ;;` 默认分支 → 报错。

### 解决

在 `pkg_deps` 函数里加 libmd 分支（[build.sh:80-81](file:///workspace/haisa-des-bootstrap/build-system/build.sh#L80-L81)）：

```bash
# libmd：BSD 风格 MD5/SHA 摘要库，dpkg 硬依赖（bionic 不导出 MD5Init）
libmd)           echo "" ;;
```

### 通用规律

**新增包时的三处必改**（缺一不可）：
1. `ALL_PACKAGES` 列表加包名（构建顺序）
2. `pkg_deps()` 函数加 `case` 分支（依赖声明，无依赖也要 `echo ""`）
3. `packages/<name>/build.sh` 创建包定义文件

漏掉第 2 步会导致"编译成功但 build.sh 报未知包"的诡异现象。建议在 `pkg_deps` 的 `*) die "未知包: $1" ;;` 之前加一个 sanity check，或在 CI 里加一个 `./build.sh list` 的预检步骤。

---

## 坑 8.6：dpkg 架构探测失败（ostable/tupletable 格式错误）

**包**：dpkg 1.22.22
**对应文件**：[packages/dpkg/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh)

### 现象

dpkg configure 在 libmd 检测通过后报：
```
configure: error: cannot determine host dpkg architecture
```

### 根因

dpkg configure 运行 `dpkg-architecture.pl -taarch64-linux-android -qDEB_HOST_ARCH` 来确定 Debian 架构名。这个 perl 脚本通过两步映射：

1. **ostable**：GNU triple OS 部分 → Debian OS 名
   - 格式：`<Debian名>\t<GNU名>\t<正则>`
   - 脚本用 `^(.*-)?$regex$` 锚尾匹配，regex 必须精确匹配 `linux-android`
   - 旧条目 `linux-android\t\t\tlinux` 的 regex 是 `linux`，被 `$` 锚尾后匹配不到 `linux-android`

2. **tupletable**：Debian tuple（`abi-libc-os-cpu`）→ Debian arch name
   - 格式：`<Debian tuple>\t<Debian arch>`
   - 旧条目 `aarch64-linux-android\t\t\tarm64` 用的是 GNU triple 而非 Debian tuple，完全无效

### 解决

正确格式的 ostable 条目（[build.sh:34-37](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh#L34-L37)）：

```bash
# Debian 名 "base-bionic-linux" = abi(base)+libc(bionic)+kernel(linux)
# gnutriplet_to_debtuple 把 $os split(/-/,3) → ("base","bionic","linux")
# 再拼 cpu("arm64") → tuple "base-bionic-linux-arm64"
printf 'base-bionic-linux\t\tlinux-android\t\tlinux-android\n' >> "$src/data/ostable"
```

正确的 tupletable 条目（[build.sh:41-43](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh#L41-L43)）：

```bash
# .deb 用 Architecture: aarch64（Termux 惯例），映射到 aarch64
printf 'base-bionic-linux-arm64\t\taarch64\n' >> "$src/data/tupletable"
```

### 映射流程详解

```
GNU triple: aarch64-linux-android
    ↓ gnutriplet_to_debtuple()
    ↓ cputable: "aarch64" → cpu="arm64"
    ↓ ostable:  "linux-android" regex match → os="base-bionic-linux"
    ↓ split(/-/,3): ("base","bionic","linux") + ("arm64")
    ↓
Debian tuple: base-bionic-linux-arm64
    ↓ debtuple_to_debarch()
    ↓ tupletable lookup: "base-bionic-linux-arm64" → "aarch64"
    ↓
Debian arch: aarch64
```

### 通用规律

**dpkg 的 ostable/tupletable 不是简单的"GNU triple → arch"映射**，而是两步：
1. ostable 把 GNU triple 的 OS 部分（如 `linux-android`）映射到 Debian OS 名（如 `base-bionic-linux`），这个名字会被 split 成 `abi-libc-kernel` 三元组
2. tupletable 把完整 Debian tuple（`abi-libc-kernel-cpu`，如 `base-bionic-linux-arm64`）映射到 Debian arch name（如 `aarch64`）

**关键易错点**：
- ostable 的 regex 被 `$` 锚尾，`linux` 匹配不到 `linux-android`
- tupletable 的 key 是 Debian tuple（`base-bionic-linux-arm64`），不是 GNU triple
- Debian arch name 必须和 .deb 文件的 `Architecture:` 字段一致（我们用 `aarch64`）

---

## 坑 9：SDL2 pkg-config 返回设备路径

**包**：sdl2_image / sdl2_mixer / sdl2_ttf
**对应文件**：[packages/sdl2_image/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/sdl2_image/build.sh)

### 现象

```
fatal error: 'SDL.h' file not found
```

### 根因

SDL2 用 CMake 构建，手写的 `sdl2.pc` 里 `prefix=$PREFIX` 是设备路径。pkg-config 返回的 cflags 是 `-I/data/data/com.haisades/files/usr/include/SDL2`（CI 主机不存在）。

### 解决

不依赖 pkg-config，直接覆盖 `SDL_CFLAGS`/`SDL_LIBS` 指向 staging（[sdl2_image/build.sh:17-18](file:///workspace/haisa-des-bootstrap/build-system/packages/sdl2_image/build.sh#L17-L18)）：

```bash
export SDL_CFLAGS="-I$STAGE_DIR$PREFIX/include/SDL2"
export SDL_LIBS="-L$STAGE_DIR$PREFIX/lib -lSDL2"
```

sdl2 包本身还手写了 `sdl2-config` 脚本（供 pygame setup.py 调用），用 `$STAGE_DIR` 环境变量让路径在 CI 和设备上都能工作（[sdl2/build.sh:91-110](file:///workspace/haisa-des-bootstrap/build-system/packages/sdl2/build.sh#L91-L110)）。

### 通用规律

**pkg-config 是交叉编译的隐形地雷**：`.pc` 文件里的 `prefix=` 通常是设备路径，CI 主机找不到。解决方案优先级：
1. 显式设置 `<dep>_CFLAGS`/`<dep>_LIBS` 环境变量（推荐）
2. 修改 `.pc` 文件的 `prefix=` 为 staging 路径
3. 设置 `PKG_CONFIG_PATH` + `PKG_CONFIG_SYSROOT_DIR`（复杂，不推荐）

---

## 坑 10：SDL2 示例程序链接失败（undefined symbol: main）

**包**：sdl2_image / sdl2_mixer / sdl2_ttf
**对应文件**：[packages/sdl2_image/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/sdl2_image/build.sh)

### 现象

```
ld.lld: error: undefined symbol: main
```

### 根因

SDL2 的 `SDL_main.h` 用宏把 `main` 重定义为 `SDL_main`（Android 平台机制，让 SDL 接管入口点）。SDL2 的示例程序（playwave/playmus 等）的 `main` 被宏吃掉，链接时找不到 `main` 符号。

### 解决

跳过 examples 构建（[sdl2_image/build.sh:29-30](file:///workspace/haisa-des-bootstrap/build-system/packages/sdl2_image/build.sh#L29-L30)）：

```bash
make -j"$JOBS" noinst_PROGRAMS=
stage_install noinst_PROGRAMS=
```

sdl2_mixer 2.8 的 Makefile 是手写的（非 automake），`noinst_PROGRAMS=` 无效，需直接 sed 覆盖 `all` 目标（[sdl2_mixer/build.sh:28](file:///workspace/haisa-des-bootstrap/build-system/packages/sdl2_mixer/build.sh#L28)）：

```bash
sed -i 's|^all:.*|all: $(srcdir)/configure Makefile $(objects)/$(TARGET)|' Makefile
make -j"$JOBS"
make install-hdrs install-lib DESTDIR="$PKG_STAGE"
```

### 通用规律

**Android 平台的 `SDL_main` 宏陷阱**：任何用 SDL2 的程序都会被宏吃掉 `main`。交叉编译 SDL2 生态的库时，必须跳过 examples/tests 链接，只编译库本身。

---

## 坑 11：SHA256 过期（上游重新发布）

**包**：sdl2_mixer 2.8.0 / sdl2_ttf 2.22.0 / apt 2.8.1
**对应文件**：各包的 `build.sh`

### 现象

```
sdl2_mixer: sha256 校验失败
```

### 根因

上游（GitHub Releases / salsa.debian.org）**重新发布了同版本号的 tarball**，内容有细微变化（如重新打包、metadata 变更），导致 SHA256 变化。我们记录的 SHA256 是旧值。

### 解决

重新下载上游 tarball，计算新的 SHA256，更新 `PKG_SRC_SHA256`。

```bash
curl -sSL "$PKG_SRC_URL" -o /tmp/check.tar.gz
sha256sum /tmp/check.tar.gz
# 把新值填入 build.sh
```

**验证脚本**（批量检查所有包的 SHA256）：

```bash
cd build-system/packages
for d in */; do
    name="${d%/}"
    f="$d/build.sh"
    [ -f "$f" ] || continue
    url=$(grep -E '^PKG_SRC_URL=' "$f" | sed -E "s/^PKG_SRC_URL=[\"'](.*)[\"']\$/\1/")
    sha=$(grep -E '^PKG_SRC_SHA256=' "$f" | sed -E "s/^PKG_SRC_SHA256=[\"']([0-9a-f]+)[\"']\$/\1/")
    [[ "$url" == local://* ]] && continue
    [ -z "$url" ] && continue
    fname=$(basename "$url")
    curl -sSL "$url" -o "/tmp/sha-check/$fname"
    actual=$(sha256sum "/tmp/sha-check/$fname" | awk '{print $1}')
    [ "$actual" = "$sha" ] && echo "OK    $name" || echo "FAIL  $name (expected $sha, got $actual)"
done
```

### 通用规律

**SHA256 过期不是错误，是常态**——上游 repackage 是常见操作。CI 失败时第一步检查是不是 SHA256 不匹配，重新下载验证即可。建议在 CI 里加一个 `pre-check` job 批量验证所有 SHA256，失败时立即提示，避免跑完几十个包才发现问题。

---

## 坑 12：savannah.gnu.org 网关 502/504

**包**：freetype 2.13.3（及其他从 savannah 下载的包）
**对应文件**：[lib/common.sh](file:///workspace/haisa-des-bootstrap/build-system/lib/common.sh) 的 `fetch_pkg`

### 现象

```
curl: (22) The requested URL returned error: 502
freetype 下载失败: https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
```
重试 3 次后仍然失败。

### 根因

savannah.gnu.org 的下载镜像偶尔会因网关过载返回 502/504，持续数分钟到数十分钟。curl 默认的 `--retry 3` 只等约 7 秒（1+2+4 秒退避），不足以等过 outage。

### 解决

增强 `fetch_pkg` 的重试策略（[common.sh:38-42](file:///workspace/haisa-des-bootstrap/build-system/lib/common.sh#L38-L42)）：

```bash
log "$name: 下载 $url"
# --retry 5 --retry-delay 5：5 次重试 + 指数退避（5/10/20/40/80s ≈ 2.5 分钟）
# 应对 savannah/sourceforge 等镜像临时 502/504 网关错误（实测可持续数分钟）
# --retry-all-errors：对 HTTP 5xx 错误也重试（curl 默认只对连接错误重试）
curl -fSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
    -o "$file" "$url" || die "$name 下载失败: $url"
```

### 通用规律

**不要假设上游下载源永远稳定**。savannah / sourceforge / ftp.gnu.org 等公益镜像都有 outage 的时候。CI 的下载逻辑必须：
1. 重试次数 ≥ 5，退避间隔指数增长
2. 对 HTTP 5xx 也重试（`--retry-all-errors`）
3. 单次 connect timeout 30 秒，避免挂死

---

## 坑 13：libtool 链接时找不到 staging 库

**包**：所有依赖动态库的 autotools 包
**对应文件**：各 build.sh 的 `export LDFLAGS`

### 现象

```
ld.lld: error: unable to find library -l<dep>
```
或：
```
cannot find -l<dep>: No such file or directory
```

### 根因

交叉编译时，linker 默认只搜系统库路径（`/usr/lib` 等），不搜 staging 目录。即使依赖库已在 `$STAGE_DIR$PREFIX/lib/`，linker 也找不到。

### 解决

每个 build.sh 显式设置 LDFLAGS 指向 staging：

```bash
export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
```

**注意**：必须用 `$LDFLAGS` 变量追加，不要直接覆盖（工具链脚本已设了 NDK 相关的 LDFLAGS）。

### 通用规律

**交叉编译三件套**：每个依赖其他库的包，build.sh 开头都要设：
```bash
export CFLAGS="$CFLAGS -I$STAGE_DIR$PREFIX/include"
export LDFLAGS="$LDFLAGS -L$STAGE_DIR$PREFIX/lib"
```
对于有 `pkg-config` 支持的依赖，**同时**设置 `<dep>_CFLAGS`/`<dep>_LIBS`（如 `GMP_CFLAGS`/`GMP_LIBS`），这是最可靠的方式。

---

## 坑 14：dpkg 的 ostable/tupletable 缺少 linux-android

**包**：dpkg 1.22.22
**对应文件**：[packages/dpkg/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh)

### 现象

dpkg 运行时不识别 `aarch64-linux-android` 架构，包的 Architecture 字段映射错误。

### 根因

dpkg 的 `data/ostable` 和 `data/tupletable` 只包含标准 Debian 架构映射，没有 Android 的 `linux-android` OS 条目。

### 解决

在 `pkg_prepare_src` 里用 sed 添加映射（[build.sh:23-38](file:///workspace/haisa-des-bootstrap/build-system/packages/dpkg/build.sh#L23-L38)）：

```bash
pkg_prepare_src() {
    extract_pkg "$PKG_NAME" "$PKG_SRC_URL" "$PKG_SRC_DIR"
    local src="$SRC_DIR/$PKG_SRC_DIR"

    # ostable: 添加 linux-android -> linux 映射
    if ! grep -q '^linux-android' "$src/data/ostable" 2>/dev/null; then
        printf 'linux-android\t\t\tlinux\n' >> "$src/data/ostable"
    fi

    # tupletable: 添加 aarch64-linux-android -> arm64 映射
    if ! grep -q '^aarch64-linux-android' "$src/data/tupletable" 2>/dev/null; then
        printf 'aarch64-linux-android\t\t\tarm64\n' >> "$src/data/tupletable"
    fi
}
```

**注意**：用 `grep -q` 检查幂等性，避免重复 patch 时追加多次。

---

## 坑 15：python 交叉编译的宿主构建

**包**：python 3.13.14
**对应文件**：[packages/python/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/python/build.sh)

### 现象

```
configure: error: cross compiler cannot run test programs
```
或：
```
ModuleNotFoundError: No module named '_struct'
```

### 根因

CPython 3.11+ 交叉编译要求 `--with-build-python` 指向同版本的 **native python**（用于生成字节码、解析 setup.py 等）。工具链脚本把 CC/CXX 设成了 aarch64 交叉编译器，导致 host python 构建也用了交叉编译器 → 编出的 python 是 aarch64 二进制 → CI 主机无法执行 → 后续交叉编译失败。

### 解决

**两阶段构建**（[build.sh:22-29](file:///workspace/haisa-des-bootstrap/build-system/packages/python/build.sh#L22-L29)）：

```bash
# 1. 先用系统默认编译器构建 native host python
local host_build="$srcdir/build-host"
rm -rf "$host_build"; mkdir -p "$host_build"
( cd "$host_build" && \
    CC=cc CXX=c++ CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS= CPPFLAGS= \
    ../configure --without-ensurepip --without-pymalloc \
    && make -j"$JOBS" python )

# 2. 再用交叉编译器构建目标 python，指定 --with-build-python
( cd "$cross_build" && \
    ../configure \
        --host="$TARGET_TRIPLE" \
        --with-build-python="$host_python" \
        ... )
```

### pip 安装的特殊处理

`make install` 末尾的 `compileall` 会尝试运行目标 python 生成 .pyc，aarch64 二进制无法在 x86_64 执行 → 失败。解决方案（[build.sh:57-61](file:///workspace/haisa-des-bootstrap/build-system/packages/python/build.sh#L57-L61)）：

```bash
( cd "$cross_build" && make install DESTDIR="$PKG_STAGE" ) || {
    warn "make install 部分步骤失败（可能是 compileall 交叉运行），检查核心产物..."
    [ -x "$PKG_STAGE$PREFIX/bin/python3.13" ] || die "python3.13 二进制未安装"
    [ -d "$PKG_STAGE$PREFIX/lib/python3.13" ] || die "stdlib 未安装"
}
```

`.pyc` 文件可以在设备首跑时由 python 自动生成，CI 阶段不强制。

### 通用规律

**交叉编译解释器类软件（python/ruby/perl）几乎都需要两阶段构建**：先构建 native 版本作为 build tool，再用交叉编译器构建目标版本。`--with-build-python` / `--with-build-ruby` 等选项是标准做法。

---

## 坑 16：python C 扩展的 NEEDED 库缺失

**包**：python 3.13.14
**对应文件**：[packages/python/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/python/build.sh) 的 `verify_dynload_needed`

### 现象

设备上 `import bz2` / `import ssl` 报：
```
ImportError: dlopen failed: library "libbz2.so.1.0" not found
```

### 根因

python 的 C 扩展（`lib-dynload/*.so`）的 NEEDED 记录的是依赖库的 soname（如 `libbz2.so.1.0`、`libssl.so.3`）。如果打包时只建了 `.so` / `.so.1` 软链接而漏掉 soname 名，设备上 dlopen 失败。

### 解决

CI 阶段扫描 C 扩展的 NEEDED，提前暴露问题（[build.sh:120-151](file:///workspace/haisa-des-bootstrap/build-system/packages/python/build.sh#L120-L151)）：

```bash
verify_dynload_needed() {
    local dynload="$PKG_STAGE$PREFIX/lib/python${PKG_VERSION%.*}/lib-dynload"
    local libdir="$STAGE_DIR$PREFIX/lib"
    # 用 llvm-readelf -d 扫描每个 .so 的 NEEDED
    while IFS= read -r so; do
        local needed
        needed=$("$READELF" -d "$so" 2>/dev/null | sed -n 's/.*NEEDED.*\[\([^]]*\)\].*/\1/p')
        for lib in $needed; do
            # 跳过 Bionic 系统库，检查 staging 里是否都能解析
            [ -e "$libdir/$lib" ] || [ -e "$pylibdir/$lib" ] || {
                warn "  $(basename "$so") 依赖 $lib，但 $PREFIX/lib/$lib 不存在"
                missing=$((missing + 1))
            }
        done
    done < <(find "$dynload" -name '*.so')
}
```

### 通用规律

**交叉编译产物的 NEEDED 校验是必备步骤**。用 `llvm-readelf -d` 扫描所有 `.so` 的 NEEDED，对照 staging 库目录核对每个依赖都能解析。这能在 CI 阶段暴露设备上才会出现的 dlopen 失败问题。

---

## 坑 17：apt 缺少 triehash 工具

**包**：apt 2.8.1
**对应文件**：[packages/apt/build.sh](file:///workspace/haisa-des-bootstrap/build-system/packages/apt/build.sh) + [lib/triehash](file:///workspace/haisa-des-bootstrap/build-system/lib/triehash)

### 现象

```
CMake Error at CMakeLists.txt:51 (message):
  Could not find triehash executable
```

### 根因

apt 的 CMakeLists.txt 用 `find_program(TRIEHASH_EXECUTABLE NAMES triehash)` 找 `triehash` 脚本。这个 Perl 脚本生成完美哈希函数（用于包名快速查找），**不在 apt 源码包内**，是独立的工具（Debian 包 `triehash` / CPAN `App::TrieHash`）。CI runner 上没有预装。

### 解决

1. 把 triehash 脚本 vendor 到构建系统 `lib/triehash`（来自 https://github.com/julian-klode/triehash）
2. 在 apt 的 build.sh 里把 `lib/` 加到 PATH（[build.sh:49-52](file:///workspace/haisa-des-bootstrap/build-system/packages/apt/build.sh#L49-L52)）：

```bash
export PATH="$BS_ROOT/lib:$PATH"
```

CMake 的 `find_program` 会从 PATH 找到 `triehash` 并缓存路径。

### 通用规律

**CMake 的 find_program / find_file 是隐式依赖**——不写在 CMakeLists.txt 的 `find_package` 里，容易被遗漏。遇到 `Could not find <tool>` 错误时：
1. 确认工具是 build-time 工具（只在编译主机运行，不需要交叉编译）还是 target 工具
2. build-time 工具直接加到 PATH 或用 `-D<tool>_EXECUTABLE=/path/to/tool` 指定
3. 如果工具不在系统包里，vendor 到构建系统的 `lib/` 目录

---

## 快速排查指南

### CI 失败时的诊断流程

1. **看失败步骤**：`gh run view <run-id> --repo <repo> | jq '.jobs[] | select(.conclusion=="failure") | .steps[] | select(.conclusion=="failure")'`
2. **下载日志**：`gh run view <run-id> --log-failed`（只看失败步骤，比全量 log 小得多）
3. **grep 关键错误**：
   - `configure: error` → 依赖检测问题（见坑 2/3/4/6/7/8）
   - `unable to find library -l<dep>` → LDFLAGS 问题（见坑 13）
   - `file not found` → CFLAGS/pkg-config 路径问题（见坑 9）
   - `undefined symbol: main` → SDL2 宏问题（见坑 10）
   - `not a valid libtool archive` → .la 文件路径问题（见坑 5）
   - `sha256 校验失败` → 上游 repackage（见坑 11）
   - `下载失败` + 502/504 → 网络问题（见坑 12）

### 本地验证单个包

```bash
cd build-system
TOOLCHAIN=ndk VARIANT=test ./build.sh build <包名>
# 或构建到指定包（含依赖）
TOOLCHAIN=ndk VARIANT=test ./build.sh build zlib openssl curl
```

### 检查产物完整性

```bash
# 检查 .so 文件
ls $STAGE_DIR$PREFIX/lib/lib<name>.so*
# 检查 NEEDED
$READELF -d $STAGE_DIR$PREFIX/lib/lib<name>.so | grep NEEDED
# 检查 .la 文件路径
grep "^libdir=" $STAGE_DIR$PREFIX/lib/lib<name>.la
```

### 重新验证所有 SHA256

```bash
cd build-system/packages
for d in */; do
    name="${d%/}"; f="$d/build.sh"
    [ -f "$f" ] || continue
    url=$(grep -E '^PKG_SRC_URL=' "$f" | sed -E "s/.*=[\"'](.*)[\"']/\1/")
    sha=$(grep -E '^PKG_SRC_SHA256=' "$f" | sed -E "s/.*=[\"']([0-9a-f]+)[\"']/\1/")
    [[ "$url" == local://* ]] && continue
    [ -z "$url" ] && continue
    curl -sSL "$url" -o /tmp/check.tar
    [ "$(sha256sum /tmp/check.tar | awk '{print $1}')" = "$sha" ] && echo "OK $name" || echo "FAIL $name"
done
```

---

## 维护建议

1. **新增包时**：先检查是否依赖已有包，依赖路径用 `$STAGE_DIR$PREFIX` 而非 `$PREFIX`。autotools 包的 build.sh 开头加 CFLAGS/LDFLAGS 三件套。
2. **升级版本时**：重新计算 SHA256（见坑 11），检查 configure 选项是否变化。
3. **CI 失败时**：按"快速排查指南"诊断，对照本文档对号入座。
4. **遇到新坑时**：把现象、根因、解决方案补充到本文档对应章节，附上 build.sh 的代码引用。
5. **定期验证**：每月跑一次 SHA256 批量校验脚本，提前发现上游 repackage。
