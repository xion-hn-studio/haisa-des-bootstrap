# Termux 设备端 wheel 编译指南

> 目标：在 Termux（Android 原生 aarch64 环境）上构建 haisa-des 项目所需的全部 Python wheel，并上传到 GitHub Releases。
>
> 适用场景：CI 主机（x86_64）无法运行 staging 的 aarch64 Android 动态链接 python3（QEMU 缺 bionic runtime），改用 Termux 原生环境绕开此限制。
>
> 目标读者：AI 助手（需按步骤逐条执行，遇错停下报告）。

---

## 0. 前置条件

- 已 root 或未 root 的 Android 设备（aarch64，Android 9+）
- 已安装 Termux（F-Droid 版本，非 Play Store）
- 电池电量 >50%，建议接电源
- 可用存储空间 >3GB
- 网络可达 PyPI、GitHub、pypi.org

---

## 1. Termux 环境准备

### 1.1 升级基础包

```bash
pkg update -y && pkg upgrade -y
pkg install -y python build-essential git curl wget unzip tar \
    pkg-config cmake ninja rust-golang \
    libffi libffi-static openssl-static \
    sdl2 sdl2-image sdl2-mixer sdl2-ttf \
    sdl2-dev sdl2-image-dev sdl2-mixer-dev sdl2-ttf-dev \
    freetype freetype-dev \
    libxml2 libxml2-static libxslt libxslt-static \
    libjpeg-turbo libjpeg-turbo-static \
    libpng libpng-static \
    zlib zlib-static \
    bzip2 bzip2-static \
    xz xz-static \
    liblz4 liblz4-static \
    zstd zstd-static \
    brotli brotli-static \
    libiconv libiconv-static \
    iconv \
    gettext gettext-static \
    libprotobuf libprotobuf-static \
    postgresql postgresql-dev \
    mysql libmysqlclient-dev \
    sqlite libsqlite \
    mpdecimal mpdecimal-dev
```

> 验证：`pkg list-installed | grep -E 'sdl2|openssl|freetype'` 应列出至少 10 行。

### 1.2 升级 pip 和 setuptools

```bash
pip install --upgrade pip wheel setuptools build
python -m pip install --upgrade pip wheel setuptools build
```

> 验证：`pip --version` 显示 pip 24+，`python --version` 显示 3.13+。

### 1.3 配置 pip 全局参数

```bash
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf <<'EOF'
[global]
# 编译安装时不要走 PyPI 缓存（占空间）
no-cache-dir = true
# 超时放宽（移动网络慢）
timeout = 300
# 国内镜像（可选，海外网络好可删）
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
EOF
```

---

## 2. 准备工作目录

### 2.1 克隆仓库

```bash
mkdir -p ~/haisa
cd ~/haisa
git clone https://github.com/xion-hn-studio/haisa-des-bootstrap.git
cd haisa-des-bootstrap
git log -1 --oneline  # 确认最新 commit
```

### 2.2 创建输出目录

```bash
mkdir -p ~/wheels-output
mkdir -p ~/wheels-src
```

---

## 3. 三种构建策略

按 PyPI 上 aarch64 wheel 的可用性，分三种策略：

| 策略 | 适用包 | 方法 |
|---|---|---|
| **A. 直接 pip download** | PyPI 已有 cp313 aarch64 manylinux wheel | `pip download --no-deps --dest ~/wheels-output` |
| **B. abi3 wheel 直接用** | PyPI 有 cp39/cp38/cp36-abi3 manylinux aarch64 wheel | 同 A，pip 会自动选 abi3 wheel |
| **C. Termux 本地编译** | PyPI 无 aarch64 wheel | `pip wheel --no-binary=:all: --no-deps` |

---

## 4. 策略 A+B：直接下载 PyPI 已有的 aarch64 wheel

以下 35 个包在 PyPI 上有 cp313-cp313-manylinux*aarch64 或 abi3 manylinux aarch64 wheel，**直接 pip download 即可**：

```bash
cd ~/wheels-output

# 一次性下载全部 PyPI 已有的 aarch64 wheel
# 分组是为了单包失败时容易定位
PIP_DOWNLOAD="pip download --no-deps --dest . --no-cache-dir --only-binary=:all:"

# A1: 数据处理 / 科学计算
$PIP_DOWNLOAD numpy==2.1.0 pandas==3.0.5 pyarrow==25.0.0 scipy==1.18.0 numba==0.66.0

# A2: JSON / 序列化
$PIP_DOWNLOAD ujson==5.13.0 orjson==3.11.9 msgpack==1.2.1 simplejson==4.1.1

# A3: 加密（abi3 wheel，pip 自动选）
$PIP_DOWNLOAD cryptography==49.0.0 pycryptodome==3.23.0 bcrypt==5.0.0

# A4: FFI / 并发 / 模板
$PIP_DOWNLOAD cffi==2.1.0 greenlet==3.5.4 markupsafe==3.0.3

# A5: 网络 / HTTP
$PIP_DOWNLOAD aiohttp==3.14.3 yarl==1.24.5 multidict==6.7.1 frozenlist==1.8.0

# A6: 数据库
$PIP_DOWNLOAD sqlalchemy==2.0.51 asyncpg==0.31.0 psycopg2-binary==2.9.12

# A7: 编译 / 类型
$PIP_DOWNLOAD cython==3.2.9 mypy==2.3.0

# A8: 配置 / 文本
$PIP_DOWNLOAD pyyaml==6.0.3 tomli==2.4.1 rtoml==0.13.0

# A9: 压缩
$PIP_DOWNLOAD zstandard==0.25.0 brotli==1.2.0 lz4==4.4.5

# A10: 字符串 / 编码
$PIP_DOWNLOAD regex==2026.7.19 chardet==7.4.3 charset-normalizer==3.4.9

# A11: 日期 / 系统工具
$PIP_DOWNLOAD pendulum==3.2.0 psutil==7.2.2 watchdog==6.0.0

# A12: 图形 / XML
$PIP_DOWNLOAD Pillow==11.0.0 pygame==2.6.1 lxml==5.3.0
```

> 验证：`ls ~/wheels-output/*.whl | wc -l` 应输出约 35。

---

## 5. 策略 C：Termux 本地编译（pygame 示例）

> pygame 2.6.1 已有 cp313 aarch64 manylinux wheel，**实际不需要本地编译**。本节作为模板，供其他 PyPI 无 aarch64 wheel 的包参考。

### 5.1 通用流程

```bash
# 1. 拉源码
cd ~/wheels-src
pip download --no-deps --no-binary=:all: --dest . <pkg>==<version>
tar -xzf <pkg>-<version>.tar.gz
cd <pkg>-<version>

# 2. 设置环境变量（让 build 找到 Termux 安装的原生库）
export PREFIX="$PREFIX"  # /data/data/com.termux/files/usr
export CFLAGS="-I$PREFIX/include $CFLAGS"
export LDFLAGS="-L$PREFIX/lib $LDFLAGS"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# 3. 编译 wheel（Termux 原生 aarch64，无交叉编译）
pip wheel --no-deps --no-build-isolation -w ~/wheels-output .

# 4. 验证 wheel 平台标签
python -c "
import zipfile, sys
whl = sys.argv[1]
with zipfile.ZipFile(whl) as z:
    name = whl.split('/')[-1]
    # wheel 文件名: name-version-py-abi-platform.whl
    parts = name.split('-')
    print('py:', parts[2] if len(parts) > 2 else '?')
    print('abi:', parts[3] if len(parts) > 3 else '?')
    print('platform:', parts[4].replace('.whl','') if len(parts) > 4 else '?')
" ~/wheels-output/<pkg>-<version>-*.whl
```

期望输出：`py: cp313` `abi: cp313` `platform: linux_aarch64`

### 5.2 pygame 特定流程（仅当 PyPI 无 wheel 时用）

```bash
cd ~/wheels-src
wget https://files.pythonhosted.org/packages/source/p/pygame/pygame-2.6.0.tar.gz
tar xzf pygame-2.6.0.tar.gz
cd pygame-2.6.0

# 设置 SDL2 路径（Termux 装在 $PREFIX）
export SDL_CONFIG="$PREFIX/bin/sdl2-config"
export CFLAGS="$($SDL_CONFIG --cflags) $CFLAGS"
export LDFLAGS="$($SDL_CONFIG --libs) $LDFLAGS"

pip wheel --no-deps --no-build-isolation -w ~/wheels-output .

ls -la ~/wheels-output/pygame-*.whl
```

### 5.3 其他常见包的 Termux 编译要点

| 包 | 关键环境变量 / 依赖 |
|---|---|
| `lxml` | `STATIC_DEPS=true`（让 pip 自己拉 libxml2/libxslt 源码静态编译） |
| `cryptography` | 需要 `rust`（已装 `rust-golang`，验证 `rustc --version`） |
| `bcrypt` | 需要 `cargo`（rust 自带） |
| `psutil` | Termux 上需 `LDFLAGS="-landroid"` |
| `pillow` | 需要 `libjpeg-turbo`、`freetype`、`libpng`（已装） |

---

## 6. 验证全部 wheel

### 6.1 列出所有 wheel

```bash
ls -la ~/wheels-output/*.whl | awk '{print $9, $5}' | sort
```

### 6.2 验证平台标签

```bash
python <<'EOF'
import os, zipfile, re
outdir = os.path.expanduser('~/wheels-output')
expected_pat = re.compile(r'cp313.*aarch64|abi3.*aarch64|py3.*aarch64|none-any')
bad = []
for fn in sorted(os.listdir(outdir)):
    if not fn.endswith('.whl'):
        continue
    parts = fn.split('-')
    if len(parts) < 5:
        print(f'WARN {fn}: 文件名段数不足')
        continue
    platform = parts[4].replace('.whl', '')
    if not expected_pat.search(fn):
        bad.append((fn, platform))
    else:
        print(f'OK   {fn}')
if bad:
    print('\n=== 平台标签异常的 wheel ===')
    for fn, p in bad:
        print(f'BAD  {fn} (platform={p})')
    raise SystemExit(1)
print(f'\n✓ 全部 {len(os.listdir(outdir))} 个 wheel 平台标签正确')
EOF
```

### 6.3 在 Termux Python 中实测 import

```bash
# 临时 venv 测试
python -m venv ~/test-venv
source ~/test-venv/bin/activate

# 装全部 wheel（不联网）
pip install --no-index --find-links ~/wheels-output ~/wheels-output/*.whl

# 逐个 import 验证
python <<'EOF'
mods = [
    'numpy', 'pandas', 'scipy', 'ujson', 'orjson', 'msgpack',
    'cryptography', 'bcrypt', 'cffi', 'greenlet', 'markupsafe',
    'aiohttp', 'yarl', 'multidict', 'frozenlist',
    'sqlalchemy', 'asyncpg', 'psycopg2',  # 注意：psycopg2 import 名是 psycopg2
    'cython', 'mypy', 'yaml',  # 注意：pyyaml import 名是 yaml
    'tomli', 'rtoml', 'zstandard', 'brotli', 'lz4',
    'regex', 'chardet', 'charset_normalizer',
    'pendulum', 'psutil', 'watchdog',
    'PIL',  # 注意：Pillow import 名是 PIL
    'pygame', 'lxml',
]
fail = []
for m in mods:
    try:
        __import__(m)
        print(f'OK   {m}')
    except Exception as e:
        print(f'FAIL {m}: {e}')
        fail.append(m)
if fail:
    print(f'\n❌ {len(fail)} 个模块 import 失败: {fail}')
    raise SystemExit(1)
print(f'\n✓ 全部 {len(mods)} 个模块 import 成功')
EOF

deactivate
rm -rf ~/test-venv
```

---

## 7. 生成 wheels-index.json

```bash
cd ~/haisa/haisa-des-bootstrap/build-system

# 把 Termux 编译的 wheel 复制到 dist/wheels/，覆盖 CI 的产物（如有）
mkdir -p dist/wheels
cp ~/wheels-output/*.whl dist/wheels/

# 生成索引
RELEASE_TAG=v0.3.0 ./make-wheels-index.sh

cat dist/wheels-index.json
```

---

## 8. 上传到 GitHub Releases

### 8.1 准备 gh CLI（如未安装）

```bash
pkg install -y gh
gh auth login  # 选 GitHub.com → HTTPS → 浏览器授权
gh auth status
```

### 8.2 上传 wheel 到指定 release

```bash
# 替换 TAG 为目标版本
TAG=v0.3.0
REPO=XION-HN/haisa-des-repo

cd ~/wheels-output

# 上传全部 wheel（--clobber 覆盖同名）
gh release upload "$TAG" --repo "$REPO" *.whl --clobber

# 同时上传 wheels-index.json
cp ~/haisa/haisa-des-bootstrap/build-system/dist/wheels-index.json .
gh release upload "$TAG" --repo "$REPO" wheels-index.json --clobber

# 验证 release 已发布的资产
gh release view "$TAG" --repo "$REPO"
```

---

## 9. 清理

```bash
# 编译缓存（pip wheel 会留 ~/.cache/pip）
rm -rf ~/.cache/pip

# 源码缓存
rm -rf ~/wheels-src

# 输出目录（确认已上传后再删）
# rm -rf ~/wheels-output
```

---

## 10. 常见错误处理

| 错误 | 原因 | 解决 |
|---|---|---|
| `error: command 'gcc' failed` | 缺编译器 | `pkg install build-essential` |
| `fatal error: SDL.h: No such file` | 缺 SDL2 头文件 | `pkg install sdl2-dev` |
| `error: Couldn't find OpenSSL` | OpenSSL 头文件缺失 | `pkg install openssl-static` |
| `cargo: command not found` | 缺 rust（cryptography/bcrypt 需要） | `pkg install rust-golang` |
| `error: linker 'cc' not found` | build-essential 未装全 | 重装 `pkg install build-essential` |
| `Permission denied` 写 /sdcard | Termux 无 storage 权限 | `termux-setup-storage` |
| `pip download` 找不到 aarch64 wheel | 该包无 aarch64 manylinux wheel | 改用策略 C 本地编译 |
| `illegal instruction` import 时 | 设备 CPU 不支持某指令 | 该包需重新编译时加 `-march=native` |

---

## 11. 完整清单（39 个包）

| # | 包名 | 版本 | 策略 | 备注 |
|---|---|---|---|---|
| 1 | numpy | 2.1.0 | A | cp313 manylinux aarch64 |
| 2 | pandas | 3.0.5 | A | cp313 |
| 3 | pyarrow | 25.0.0 | A | cp313 |
| 4 | scipy | 1.18.0 | A | cp313 |
| 5 | numba | 0.66.0 | A | cp313 |
| 6 | ujson | 5.13.0 | A | cp313 |
| 7 | orjson | 3.11.9 | A | cp313 |
| 8 | msgpack | 1.2.1 | A | cp313 |
| 9 | simplejson | 4.1.1 | A | cp313 |
| 10 | cryptography | 49.0.0 | B | cp39-abi3（stable ABI，cp313 兼容） |
| 11 | pycryptodome | 3.23.0 | B | cp37-abi3 |
| 12 | bcrypt | 5.0.0 | B | cp38-abi3 |
| 13 | cffi | 2.1.0 | A | cp313 |
| 14 | greenlet | 3.5.4 | A | cp313 |
| 15 | markupsafe | 3.0.3 | A | cp313 |
| 16 | aiohttp | 3.14.3 | A | cp313 |
| 17 | yarl | 1.24.5 | A | cp313 |
| 18 | multidict | 6.7.1 | A | cp313 |
| 19 | frozenlist | 1.8.0 | A | cp313 |
| 20 | sqlalchemy | 2.0.51 | A | cp313 |
| 21 | asyncpg | 0.31.0 | A | cp313 |
| 22 | psycopg2-binary | 2.9.12 | A | cp313 |
| 23 | cython | 3.2.9 | A | cp313 |
| 24 | mypy | 2.3.0 | A | cp313 |
| 25 | pyyaml | 6.0.3 | A | cp313 |
| 26 | tomli | 2.4.1 | A | cp313 |
| 27 | rtoml | 0.13.0 | A | cp313 |
| 28 | zstandard | 0.25.0 | A | cp313 |
| 29 | brotli | 1.2.0 | A | cp313 |
| 30 | lz4 | 4.4.5 | A | cp313 |
| 31 | regex | 2026.7.19 | A | cp313 |
| 32 | chardet | 7.4.3 | A | cp313 |
| 33 | charset-normalizer | 3.4.9 | A | cp313 |
| 34 | pendulum | 3.2.0 | A | cp313 |
| 35 | psutil | 7.2.2 | B | cp36-abi3 |
| 36 | watchdog | 6.0.0 | A | py3 纯 Python manylinux wheel |
| 37 | Pillow | 11.0.0 | A | cp313 |
| 38 | pygame | 2.6.1 | A | cp313 |
| 39 | lxml | 5.3.0 | A | cp313 |

**结论**：全部 39 个包都可用策略 A 或 B（直接 pip download），无需本地编译。仅需在第 6 节验证 import 时如有失败，再用策略 C 补救。

---

## 12. 执行顺序总览

```
1. Termux 环境准备（pkg install）
2. 克隆仓库 + 创建输出目录
3. 策略 A+B：pip download 全部 35+ 个包（约 5 分钟）
4. 验证 wheel 文件名平台标签
5. venv 实测 import 全部模块
6. 生成 wheels-index.json
7. 上传到 GitHub Releases
8. 清理
```

预计总耗时：15-30 分钟（取决于网络速度和设备性能）。

---

## 13. 反馈给主控 AI 的报告格式

完成后请报告：

```
Termux wheel 构建报告
=====================
设备：[型号，Android 版本]
Python 版本：[python --version]
总 wheel 数：[数字]
成功数：[数字]
失败数：[数字]
失败包列表：[包名 + 错误信息]
已上传到 release：[TAG 名]
```

如遇无法解决的错误，停下并报告完整错误日志。
