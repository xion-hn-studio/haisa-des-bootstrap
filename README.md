# haisa-des-bootstrap

bootstrap 源码仓库：交叉编译 Android aarch64 的 Linux 环境（Python 3.13 + pip + 14 个原生包），产出 `bootstrap-arm64-v8a.zip`。

## 仓库职责

- **本仓库**：bootstrap 源码（`build-system/`）+ CI 构建
- **haisa-des**：Android Java 源码，CI 从 `haisa-des-repo` Releases 拉 bootstrap 注入 APK
- **haisa-des-repo**：公开发布仓库，托管 Releases 资产（bootstrap.zip + packages.json + bootstrap-version.json）

## CI 触发

- `push` 到 `main`：构建 + 产 artifact（7 天保留，供调试）
- `push tag v*`：构建 + 上传到 `haisa-des-repo` Releases（公开发布）
- `workflow_dispatch`：手动触发

## 资源流转

```
tag 触发 → 本 CI 构建并上传到 haisa-des-repo Releases
                                      ↓
            +-------------------------+-------------------------+
            ↓                                                   ↓
   haisa-des 软件 CI（apk job）                    App 端 PackageManager
   从 Releases latest/download/ 拉                 从 Releases latest/download/ 拉
   bootstrap.zip 注入 APK                          packages.json / bootstrap-version.json
```

## 必需的 secrets

| Secret 名 | 用途 | 权限 |
|---|---|---|
| `RELEASE_REPO_TOKEN` | 跨仓库上传到 `haisa-des-repo` Releases | PAT，需 `repo:contents:write`（公开仓库勾选 `public_repo` 即可） |

## 本地构建

```bash
export ANDROID_HOME=/path/to/android/sdk
sdkmanager "ndk;29.0.14206865"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"

cd build-system
./build.sh build all
./make-bootstrap.sh
./make-packages-index.sh
./make-bootstrap-version.sh
```

产物在 `build-system/dist/`：
- `bootstrap-arm64-v8a.zip`：完整 bootstrap
- `packages/*.tar.gz`：单独包归档
- `packages.json`：包索引
- `bootstrap-version.json`：版本信息
