# libandroid-glob —— Android 7 之前 bionic 无 glob()/globfree()，apt 依赖
# NDK 提供 stub 源码 sysroot/usr/include/android/glob.h
# 实现来自 Termux 的 libandroid-glob（一组薄包装）
PKG_NAME="libandroid-glob"
PKG_VERSION="0.1"
PKG_SRC_URL="local://vendor/libandroid-glob-0.1.tar.gz"
PKG_SRC_SHA256=""
PKG_SRC_DIR="libandroid-glob-0.1"

# 自建源码目录（vendor 暂无 tarball 时用 pkg_prepare_src 生成）
# 若 vendor/ 下无 tarball，则 fetch_pkg 会跳过下载（local:// 但文件不存在会 die）
# 这里改用直接源码内嵌方式：pkg_prepare_src 创建源码目录
pkg_prepare_src() {
    mkdir -p "$SRC_DIR/$PKG_SRC_DIR"
    # glob 实现（薄包装到 opendir/readdir）
    cat > "$SRC_DIR/$PKG_SRC_DIR/glob.c" <<'EOF'
#include <glob.h>
#include <dirent.h>
#include <fnmatch.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

static int append_match(char ***buf, size_t *n, size_t *cap, const char *path) {
    char *dup = strdup(path);
    if (!dup) return GLOB_NOSPACE;
    if (*n == *cap) {
        size_t new_cap = *cap ? *cap * 2 : 16;
        char **new_buf = realloc(*buf, new_cap * sizeof(char*));
        if (!new_buf) { free(dup); return GLOB_NOSPACE; }
        *buf = new_buf; *cap = new_cap;
    }
    (*buf)[(*n)++] = dup;
    return 0;
}

static int scan_dir(const char *dir, size_t dir_len, const char *pattern,
                    int flags, int (*errfunc)(const char*, int),
                    char ***buf, size_t *n, size_t *cap) {
    DIR *d = opendir(dir);
    if (!d) {
        if (errno == ENOENT || errno == ENOTDIR) return 0;
        if (errfunc) return errfunc(dir, errno);
        return (flags & GLOB_ERR) ? GLOB_ABORTED : 0;
    }
    struct dirent *e;
    int rc = 0;
    while ((e = readdir(d)) != NULL) {
        if (fnmatch(pattern, e->d_name, 0) != 0) continue;
        char full[PATH_MAX];
        snprintf(full, sizeof(full), "%s%.*s%s", dir, (int)dir_len, "", e->d_name);
        rc = append_match(buf, n, cap, full);
        if (rc != 0) break;
    }
    closedir(d);
    return rc;
}

int glob(const char *pattern, int flags, int (*errfunc)(const char*, int),
         glob_t *pglob) {
    if (!pattern || !pglob) return GLOB_NOSPACE;
    pglob->gl_pathc = 0;
    pglob->gl_pathv = NULL;
    pglob->gl_offs = 0;

    // 简化：仅处理 / 分隔的路径
    const char *slash = strchr(pattern, '/');
    char **buf = NULL; size_t n = 0, cap = 0;
    int rc = 0;

    if (slash) {
        size_t dir_len = slash - pattern;
        char *dir = malloc(dir_len + 2);
        memcpy(dir, pattern, dir_len);
        dir[dir_len] = '/';
        dir[dir_len + 1] = '\0';
        rc = scan_dir(dir, dir_len + 1, slash + 1, flags, errfunc, &buf, &n, &cap);
        free(dir);
    } else {
        rc = scan_dir("./", 2, pattern, flags, errfunc, &buf, &n, &cap);
        // 去掉 ./ 前缀
        for (size_t i = 0; i < n; i++) {
            if (strncmp(buf[i], "./", 2) == 0) {
                memmove(buf[i], buf[i] + 2, strlen(buf[i]) - 1);
            }
        }
    }

    if (rc != 0) {
        for (size_t i = 0; i < n; i++) free(buf[i]);
        free(buf);
        return rc;
    }
    if (n == 0 && !(flags & GLOB_NOCHECK)) {
        free(buf);
        return GLOB_NOMATCH;
    }

    // 终止 NULL
    char **new_buf = realloc(buf, (n + 1) * sizeof(char*));
    if (!new_buf) {
        for (size_t i = 0; i < n; i++) free(buf[i]);
        free(buf);
        return GLOB_NOSPACE;
    }
    new_buf[n] = NULL;
    pglob->gl_pathc = n;
    pglob->gl_pathv = new_buf;
    return 0;
}

void globfree(glob_t *pglob) {
    if (!pglob || !pglob->gl_pathv) return;
    for (size_t i = 0; i < pglob->gl_pathc; i++) {
        free(pglob->gl_pathv[i]);
    }
    free(pglob->gl_pathv);
    pglob->gl_pathv = NULL;
    pglob->gl_pathc = 0;
}
EOF
}

pkg_build() {
    $CC $CFLAGS -fPIC -c glob.c -o glob.o
    $CC -shared -o libandroid-glob.so glob.o $LDFLAGS
    install -D -m 755 libandroid-glob.so "$PKG_STAGE$PREFIX/lib/libandroid-glob.so"
}
