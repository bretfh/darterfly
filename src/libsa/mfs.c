#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <pthread.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <poll.h>
#include <time.h>
#include <sys/time.h>
#include "libsa.h"

#define T_DIR 1
#define T_REG 2
#define T_CON 3
#define T_NULL 4
#define T_LNK 5
#define MAX_FDS 256

typedef struct node {
  char name[256];
  int type;
  mode_t mode;
  uid_t uid;
  gid_t gid;
  ino_t ino;
  size_t size, cap;
  char *data;
  const char *ext;
  struct timespec mtime;
  struct node *parent, *child, *next;
} node;

typedef struct { node *n; off_t off; int flags, refs; } file;

struct __DIR { node *dir, *at; int fd; struct dirent ent; };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static node *root, *cwd, *console;
static file *fds[MAX_FDS];
static file console_file = {0, 0, O_RDWR, 1000};
static ino_t next_ino = 2;

#define LOCKED(expr)              \
  ({                              \
    pthread_mutex_lock(&lock);    \
    __typeof__(expr) r_ = (expr); \
    pthread_mutex_unlock(&lock);  \
    r_;                           \
  })

static int fail(int e) {
  errno = e;
  return -1;
}

static node *make(node *parent, const char *name, int type, mode_t mode) {
  node *n = calloc(1, sizeof *n);
  strncpy(n->name, name, sizeof n->name - 1);
  n->type = type;
  n->mode = mode;
  n->ino = next_ino++;
  clock_gettime(CLOCK_REALTIME, &n->mtime);
  n->parent = parent ? parent : n;
  if (parent) {
    n->next = parent->child;
    parent->child = n;
  }
  return n;
}

static node *child(node *dir, const char *name, size_t len) {
  if (len == 1 && name[0] == '.') return dir;
  if (len == 2 && name[0] == '.' && name[1] == '.') return dir->parent;
  for (node *c = dir->child; c; c = c->next)
    if (strlen(c->name) == len && !strncmp(c->name, name, len)) return c;
  return 0;
}

static node *walk(node *start, const char *path, node **parent, const char **last, int follow, int depth);

static node *resolve_link(node *n, int depth) {
  if (depth > 32) { errno = ELOOP; return 0; }
  return walk(n->parent, n->data, 0, 0, 1, depth + 1);
}

static node *walk(node *start, const char *path, node **parent, const char **last, int follow, int depth) {
  node *n = path[0] == '/' ? root : start;
  const char *p = path;
  if (parent) *parent = 0;
  for (;;) {
    while (*p == '/') p++;
    if (!*p) return n;
    const char *end = strchr(p, '/');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    if (n->type != T_DIR) { errno = ENOTDIR; return 0; }
    node *c = child(n, p, len);
    const char *rest = p + len;
    while (*rest == '/') rest++;
    if (!c) {
      if (!*rest && parent) {
        *parent = n;
        *last = p;
      }
      errno = ENOENT;
      return 0;
    }
    if (c->type == T_LNK && (*rest || follow)) {
      if (!*rest && parent) {
        *parent = n;
        *last = p;
      }
      c = resolve_link(c, depth);
      if (!c) return 0;
    }
    n = c;
    p = rest;
  }
}

static node *lookup(const char *path, node **parent, const char **last) { return walk(cwd, path, parent, last, 1, 0); }
static node *lookup_nofollow(const char *path, node **parent, const char **last) { return walk(cwd, path, parent, last, 0, 0); }

static int leaf_name(const char *last, char *name) {
  size_t len = strcspn(last, "/");
  if (len > 255) return fail(ENAMETOOLONG);
  memcpy(name, last, len);
  name[len] = 0;
  return 0;
}

static node *mkdirs(const char *path) {
  node *n = root;
  const char *p = path;
  for (;;) {
    while (*p == '/') p++;
    if (!*p) return n;
    const char *end = strchr(p, '/');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    char name[256];
    if (len > 255) len = 255;
    memcpy(name, p, len);
    name[len] = 0;
    node *c = child(n, p, len);
    if (!c) c = make(n, name, T_DIR, 0755);
    n = c;
    p += len;
  }
}

static void own_data(node *n, size_t need) {
  if (n->ext || need > n->cap) {
    size_t cap = need < 256 ? 256 : need * 2;
    char *d = malloc(cap);
    memcpy(d, n->ext ? n->ext : n->data, n->size);
    if (!n->ext) free(n->data);
    n->data = d;
    n->ext = 0;
    n->cap = cap;
  }
}

static const char *bytes(node *n) { return n->ext ? n->ext : n->data; }

static int install(file *f) {
  for (int i = 0; i < MAX_FDS; i++)
    if (!fds[i]) {
      fds[i] = f;
      return i;
    }
  return fail(EMFILE);
}

static file *get(int fd) {
  if (fd < 0 || fd >= MAX_FDS || !fds[fd]) {
    errno = EBADF;
    return 0;
  }
  return fds[fd];
}

static void load_cpio(const char *a, size_t size) {
  size_t at = 0;
  while (at + 110 <= size && !strncmp(a + at, "070701", 6)) {
    char field[9] = {0};
#define HEX(i) (memcpy(field, a + at + 6 + 8 * (i), 8), strtoul(field, 0, 16))
    unsigned long mode = HEX(1), filesize = HEX(6), namesize = HEX(11);
    const char *name = a + at + 110;
    size_t data = (at + 110 + namesize + 3) & ~3ul;
    if (!strcmp(name, "TRAILER!!!")) break;
    if ((mode & S_IFMT) == S_IFDIR)
      mkdirs(name);
    else if ((mode & S_IFMT) == S_IFREG) {
      char dir[1024];
      strncpy(dir, name, sizeof dir - 1);
      char *slash = strrchr(dir, '/');
      node *parent = root;
      const char *base = name;
      if (slash) {
        *slash = 0;
        parent = mkdirs(dir);
        base = name + (slash - dir) + 1;
      }
      node *n = make(parent, base, T_REG, mode & 07777);
      n->ext = a + data;
      n->size = filesize;
    }
    at = (data + filesize + 3) & ~3ul;
  }
}

void __libsa_mfs_init(void) {
  root = make(0, "/", T_DIR, 0755);
  cwd = root;
  node *dev = mkdirs("/dev");
  console = make(dev, "console", T_CON, 0620);
  make(dev, "tty", T_CON, 0666)->type = T_CON;
  make(dev, "null", T_NULL, 0666);
  console_file.n = console;
  fds[0] = fds[1] = fds[2] = &console_file;
  mkdirs("/tmp");
  uint64_t kernel[2] = {0, 0}, ramdisk[2] = {0, 0};
  __machdep(MACHDEP_kernel_file, (long)kernel, 0);
  node *k = make(mkdirs("/System/Library/Kernels"), "kernel", T_REG, 0555);
  k->ext = (const char *)kernel[0];
  k->size = kernel[1];
  __machdep(MACHDEP_ramdisk, (long)ramdisk, 0);
  if (ramdisk[0]) load_cpio((const char *)ramdisk[0], ramdisk[1]);
}

static ssize_t console_read(void *buf, size_t n) { return __syscall(SYS_read, 0, (long)buf, (long)n, 0, 0, 0); }
static ssize_t console_write(const void *buf, size_t n) { return __syscall(SYS_write, 1, (long)buf, (long)n, 0, 0, 0); }

static ssize_t do_read(file *f, void *buf, size_t n, off_t *off) {
  node *x = f->n;
  if (x->type == T_CON) return -2;
  if (x->type == T_NULL) return 0;
  if (x->type == T_DIR) return fail(EISDIR);
  if ((f->flags & O_ACCMODE) == O_WRONLY) return fail(EBADF);
  if ((size_t)*off >= x->size) return 0;
  if (n > x->size - *off) n = x->size - *off;
  memcpy(buf, bytes(x) + *off, n);
  *off += n;
  return (ssize_t)n;
}

static ssize_t do_write(file *f, const void *buf, size_t n, off_t *off) {
  node *x = f->n;
  if (x->type == T_CON) return -2;
  if (x->type == T_NULL) return (ssize_t)n;
  if ((f->flags & O_ACCMODE) == O_RDONLY) return fail(EBADF);
  if (f->flags & O_APPEND) *off = (off_t)x->size;
  size_t end = (size_t)*off + n;
  own_data(x, end > x->size ? end : x->size);
  if ((size_t)*off > x->size) memset(x->data + x->size, 0, *off - x->size);
  memcpy(x->data + *off, buf, n);
  if (end > x->size) x->size = end;
  *off += n;
  clock_gettime(CLOCK_REALTIME, &x->mtime);
  return (ssize_t)n;
}

ssize_t read(int fd, void *buf, size_t n) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  ssize_t r = f ? do_read(f, buf, n, &f->off) : -1;
  pthread_mutex_unlock(&lock);
  return r == -2 ? console_read(buf, n) : r;
}

ssize_t write(int fd, const void *buf, size_t n) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  ssize_t r = f ? do_write(f, buf, n, &f->off) : -1;
  pthread_mutex_unlock(&lock);
  return r == -2 ? console_write(buf, n) : r;
}

ssize_t pread(int fd, void *buf, size_t n, off_t off) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  ssize_t r = f ? (f->n->type == T_CON ? fail(ESPIPE) : do_read(f, buf, n, &off)) : -1;
  pthread_mutex_unlock(&lock);
  return r;
}

ssize_t pwrite(int fd, const void *buf, size_t n, off_t off) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  ssize_t r = f ? (f->n->type == T_CON ? fail(ESPIPE) : do_write(f, buf, n, &off)) : -1;
  pthread_mutex_unlock(&lock);
  return r;
}

static int do_open(const char *path, int flags, mode_t mode) {
  node *parent;
  const char *last;
  node *n = lookup(path, &parent, &last);
  if (n && (flags & O_CREAT) && (flags & O_EXCL)) return fail(EEXIST);
  if (!n) {
    if (!(flags & O_CREAT) || !parent) return -1;
    char name[256];
    size_t len = strcspn(last, "/");
    if (len > 255) return fail(ENAMETOOLONG);
    memcpy(name, last, len);
    name[len] = 0;
    n = make(parent, name, T_REG, mode & 07777);
  }
  if ((flags & O_DIRECTORY) && n->type != T_DIR) return fail(ENOTDIR);
  if (n->type == T_DIR && (flags & O_ACCMODE) != O_RDONLY) return fail(EISDIR);
  if ((flags & O_TRUNC) && n->type == T_REG && (flags & O_ACCMODE) != O_RDONLY) {
    own_data(n, 0);
    n->size = 0;
  }
  file *f = calloc(1, sizeof *f);
  f->n = n;
  f->flags = flags;
  f->refs = 1;
  int fd = install(f);
  if (fd < 0) free(f);
  return fd;
}

int open(const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = (flags & O_CREAT) ? va_arg(ap, mode_t) : 0;
  va_end(ap);
  return LOCKED(do_open(path, flags, mode));
}

int openat(int dir, const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = (flags & O_CREAT) ? va_arg(ap, mode_t) : 0;
  va_end(ap);
  (void)dir;
  return LOCKED(do_open(path, flags, mode));
}

int creat(const char *path, mode_t mode) { return open(path, O_WRONLY | O_CREAT | O_TRUNC, mode); }

static int do_close(int fd) {
  file *f = get(fd);
  if (!f) return -1;
  fds[fd] = 0;
  if (f != &console_file && --f->refs == 0) free(f);
  return 0;
}

int close(int fd) { return LOCKED(do_close(fd)); }

static off_t do_lseek(int fd, off_t off, int whence) {
  file *f = get(fd);
  if (!f) return -1;
  if (f->n->type == T_CON) return fail(ESPIPE);
  off_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? f->off : (off_t)f->n->size;
  if (base + off < 0) return fail(EINVAL);
  return f->off = base + off;
}

off_t lseek(int fd, off_t off, int whence) { return LOCKED(do_lseek(fd, off, whence)); }

static void fill_stat(node *n, struct stat *st) {
  memset(st, 0, sizeof *st);
  st->st_ino = n->ino;
  st->st_nlink = n->type == T_DIR ? 2 : 1;
  st->st_uid = n->uid;
  st->st_gid = n->gid;
  st->st_size = n->type == T_REG ? (off_t)n->size : 0;
  st->st_blksize = 4096;
  st->st_blocks = (st->st_size + 511) / 512;
  st->st_atim = st->st_mtim = st->st_ctim = n->mtime;
  switch (n->type) {
  case T_DIR: st->st_mode = S_IFDIR | n->mode; break;
  case T_LNK: st->st_mode = S_IFLNK | n->mode; st->st_size = (off_t)n->size; break;
  case T_REG: st->st_mode = S_IFREG | n->mode; break;
  default:
    st->st_mode = S_IFCHR | n->mode;
    st->st_rdev = n->type == T_NULL ? 0x103 : 0x501;
  }
}

static int do_fstat(int fd, struct stat *st) {
  file *f = get(fd);
  if (!f) return -1;
  fill_stat(f->n, st);
  return 0;
}

static int do_stat(const char *path, struct stat *st) {
  node *n = lookup(path, 0, 0);
  if (!n) return -1;
  fill_stat(n, st);
  return 0;
}

int fstat(int fd, struct stat *st) { return LOCKED(do_fstat(fd, st)); }
int stat(const char *path, struct stat *st) { return LOCKED(do_stat(path, st)); }
static int do_lstat(const char *path, struct stat *st) {
  node *n = lookup_nofollow(path, 0, 0);
  if (!n) return -1;
  fill_stat(n, st);
  return 0;
}

int lstat(const char *path, struct stat *st) { return LOCKED(do_lstat(path, st)); }

static int do_symlink(const char *target, const char *path) {
  node *parent;
  const char *last;
  if (lookup_nofollow(path, &parent, &last)) return fail(EEXIST);
  if (!parent) return -1;
  char name[256];
  if (leaf_name(last, name) < 0) return -1;
  node *n = make(parent, name, T_LNK, 0755);
  n->size = strlen(target);
  n->data = strdup(target);
  n->cap = n->size + 1;
  return 0;
}

int symlink(const char *target, const char *path) { return LOCKED(do_symlink(target, path)); }

static ssize_t do_readlink(const char *path, char *buf, size_t size) {
  node *n = lookup_nofollow(path, 0, 0);
  if (!n) return -1;
  if (n->type != T_LNK) return fail(EINVAL);
  size_t len = n->size < size ? n->size : size;
  memcpy(buf, n->data, len);
  return (ssize_t)len;
}

ssize_t readlink(const char *path, char *buf, size_t size) { return LOCKED(do_readlink(path, buf, size)); }
int access(const char *path, int mode) { struct stat st; (void)mode; return stat(path, &st); }

static int do_mkdir(const char *path, mode_t mode) {
  node *parent;
  const char *last;
  if (lookup(path, &parent, &last)) return fail(EEXIST);
  if (!parent) return -1;
  char name[256];
  size_t len = strcspn(last, "/");
  if (len > 255) return fail(ENAMETOOLONG);
  memcpy(name, last, len);
  name[len] = 0;
  make(parent, name, T_DIR, mode & 07777);
  return 0;
}

int mkdir(const char *path, mode_t mode) { return LOCKED(do_mkdir(path, mode)); }

static void detach(node *n) {
  node **p = &n->parent->child;
  while (*p && *p != n) p = &(*p)->next;
  if (*p) *p = n->next;
}

static int do_remove(const char *path, int dir) {
  node *n = lookup_nofollow(path, 0, 0);
  if (!n) return -1;
  if (n == root || n == cwd) return fail(EBUSY);
  if (dir && n->type != T_DIR) return fail(ENOTDIR);
  if (!dir && n->type == T_DIR) return fail(EISDIR);
  if (dir && n->child) return fail(ENOTEMPTY);
  detach(n);
  return 0;
}

int rmdir(const char *path) { return LOCKED(do_remove(path, 1)); }
int unlink(const char *path) { return LOCKED(do_remove(path, 0)); }
int remove(const char *path) {
  struct stat st;
  if (stat(path, &st) < 0) return -1;
  return S_ISDIR(st.st_mode) ? rmdir(path) : unlink(path);
}

static int do_rename(const char *from, const char *to) {
  node *n = lookup_nofollow(from, 0, 0);
  if (!n) return -1;
  node *parent;
  const char *last;
  char name[256];
  node *old = lookup_nofollow(to, &parent, &last);
  if (old) {
    if (old == n) return 0;
    if (n->type == T_DIR && old->type != T_DIR) return fail(ENOTDIR);
    if (n->type != T_DIR && old->type == T_DIR) return fail(EISDIR);
    if (old->type == T_DIR && old->child) return fail(ENOTEMPTY);
    parent = old->parent;
    strcpy(name, old->name);
  } else {
    if (!parent) return -1;
    if (leaf_name(last, name) < 0) return -1;
  }
  for (node *p = parent; ; p = p->parent) {
    if (p == n) return fail(EINVAL);
    if (p == root) break;
  }
  if (old) detach(old);
  detach(n);
  strcpy(n->name, name);
  n->parent = parent;
  n->next = parent->child;
  parent->child = n;
  return 0;
}

int rename(const char *from, const char *to) { return LOCKED(do_rename(from, to)); }

static int do_chdir(const char *path) {
  node *n = lookup(path, 0, 0);
  if (!n) return -1;
  if (n->type != T_DIR) return fail(ENOTDIR);
  cwd = n;
  return 0;
}

int chdir(const char *path) { return LOCKED(do_chdir(path)); }

static int do_fchdir(int fd) {
  file *f = get(fd);
  if (!f) return -1;
  if (f->n->type != T_DIR) return fail(ENOTDIR);
  cwd = f->n;
  return 0;
}

int fchdir(int fd) { return LOCKED(do_fchdir(fd)); }

static size_t path_of(node *n, char *buf, size_t size) {
  if (n == root) {
    if (size > 1) strcpy(buf, "/");
    return 1;
  }
  size_t at = path_of(n->parent, buf, size);
  if (at == 1) at = 0;
  size_t len = strlen(n->name);
  if (at + len + 2 <= size) {
    buf[at] = '/';
    memcpy(buf + at + 1, n->name, len + 1);
  }
  return at + len + 1;
}

char *getcwd(char *buf, size_t n) {
  pthread_mutex_lock(&lock);
  char tmp[4096];
  size_t len = path_of(cwd, tmp, sizeof tmp);
  pthread_mutex_unlock(&lock);
  if (!buf) return strdup(tmp);
  if (len + 1 > n) { errno = ERANGE; return 0; }
  memcpy(buf, tmp, len + 1);
  return buf;
}

char *realpath(const char *path, char *out) {
  pthread_mutex_lock(&lock);
  node *n = lookup(path, 0, 0);
  char tmp[4096];
  if (n) path_of(n, tmp, sizeof tmp);
  pthread_mutex_unlock(&lock);
  if (!n) return 0;
  if (!out) return strdup(tmp);
  strcpy(out, tmp);
  return out;
}

static int set_mode(node *n, mode_t m) {
  if (!n) return -1;
  n->mode = m & 07777;
  return 0;
}

int chmod(const char *path, mode_t m) { return LOCKED(set_mode(lookup(path, 0, 0), m)); }
int fchmod(int fd, mode_t m) { return LOCKED(get(fd) ? set_mode(get(fd)->n, m) : -1); }

static int set_owner(node *n, uid_t u, gid_t g) {
  if (!n) return -1;
  if (u != (uid_t)-1) n->uid = u;
  if (g != (gid_t)-1) n->gid = g;
  return 0;
}

int chown(const char *path, uid_t u, gid_t g) { return LOCKED(set_owner(lookup(path, 0, 0), u, g)); }
int lchown(const char *path, uid_t u, gid_t g) { return chown(path, u, g); }
int fchown(int fd, uid_t u, gid_t g) { return LOCKED(get(fd) ? set_owner(get(fd)->n, u, g) : -1); }

static int do_truncate(node *n, off_t len) {
  if (!n) return -1;
  if (n->type != T_REG) return fail(EINVAL);
  own_data(n, (size_t)len > n->size ? (size_t)len : n->size);
  if ((size_t)len > n->size) memset(n->data + n->size, 0, len - n->size);
  n->size = (size_t)len;
  return 0;
}

int truncate(const char *path, off_t len) { return LOCKED(do_truncate(lookup(path, 0, 0), len)); }
int ftruncate(int fd, off_t len) { return LOCKED(get(fd) ? do_truncate(get(fd)->n, len) : -1); }
int fsync(int fd) { return LOCKED(get(fd) ? 0 : -1); }
int fdatasync(int fd) { return fsync(fd); }
void sync(void) {}

static int do_dup2(int a, int b) {
  file *f = get(a);
  if (!f) return -1;
  if (b < 0 || b >= MAX_FDS) return fail(EBADF);
  if (a == b) return b;
  if (fds[b]) do_close(b);
  fds[b] = f;
  f->refs++;
  return b;
}

static int do_dup(int a) {
  file *f = get(a);
  if (!f) return -1;
  int fd = install(f);
  if (fd >= 0) f->refs++;
  return fd;
}

int dup(int fd) { return LOCKED(do_dup(fd)); }
int dup2(int a, int b) { return LOCKED(do_dup2(a, b)); }

int fcntl(int fd, int cmd, ...) {
  va_list ap;
  va_start(ap, cmd);
  long arg = va_arg(ap, long);
  va_end(ap);
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  int r = -1;
  if (f) switch (cmd) {
    case F_GETFL: r = f->flags; break;
    case F_SETFL: f->flags = (f->flags & O_ACCMODE) | ((int)arg & ~O_ACCMODE); r = 0; break;
    case F_GETFD: case F_SETFD: r = 0; break;
    case F_DUPFD: {
      for (int i = (int)arg; i < MAX_FDS; i++)
        if (!fds[i]) {
          fds[i] = f;
          f->refs++;
          r = i;
          break;
        }
      if (r < 0) errno = EMFILE;
      break;
    }
    default: r = 0;
    }
  pthread_mutex_unlock(&lock);
  return r;
}

int isatty(int fd) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  int r = f && f->n->type == T_CON;
  pthread_mutex_unlock(&lock);
  if (!r) errno = ENOTTY;
  return r;
}

int ioctl(int fd, unsigned long req, ...) {
  if (!isatty(fd)) return fail(ENOTTY);
  if (req == TIOCGWINSZ) {
    va_list ap;
    va_start(ap, req);
    struct winsize *w = va_arg(ap, struct winsize *);
    va_end(ap);
    w->ws_row = 25;
    w->ws_col = 80;
    w->ws_xpixel = w->ws_ypixel = 0;
    return 0;
  }
  return fail(ENOTTY);
}

char *ttyname(int fd) { return isatty(fd) ? "/dev/console" : 0; }

static DIR *open_dir(node *n, int fd) {
  if (!n) return 0;
  if (n->type != T_DIR) { errno = ENOTDIR; return 0; }
  DIR *d = calloc(1, sizeof *d);
  d->dir = n;
  d->at = n->child;
  d->fd = fd;
  return d;
}

DIR *opendir(const char *path) { return LOCKED(open_dir(lookup(path, 0, 0), -1)); }
DIR *fdopendir(int fd) { return LOCKED(get(fd) ? open_dir(get(fd)->n, fd) : (DIR *)0); }

struct dirent *readdir(DIR *d) {
  pthread_mutex_lock(&lock);
  node *n = d->at;
  if (n) d->at = n->next;
  struct dirent *e = 0;
  if (n) {
    d->ent.d_ino = n->ino;
    d->ent.d_type = n->type == T_DIR ? 4 : n->type == T_REG ? 8 : 2;
    strcpy(d->ent.d_name, n->name);
    e = &d->ent;
  }
  pthread_mutex_unlock(&lock);
  return e;
}

struct dirent *readdir64(DIR *d) { return readdir(d); }
int closedir(DIR *d) { if (d->fd >= 0) close(d->fd); free(d); return 0; }
int dirfd(DIR *d) { return d->fd; }

static void fill_template(char *t) {
  static unsigned counter;
  char *x = t + strlen(t);
  unsigned v = (unsigned)__syscall(SYS_thread_selfid, 0, 0, 0, 0, 0, 0) * 7919 + ++counter * 104729;
  while (x > t && x[-1] == 'X') {
    *--x = "abcdefghijklmnopqrstuvwxyz0123456789"[v % 36];
    v = v / 36 + counter * 31;
  }
}

int mkstemp(char *t) {
  for (int i = 0; i < 100; i++) {
    char copy[4096];
    strncpy(copy, t, sizeof copy - 1);
    fill_template(copy);
    int fd = open(copy, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
      strcpy(t, copy);
      return fd;
    }
    if (errno != EEXIST) return -1;
  }
  return -1;
}

char *mkdtemp(char *t) {
  for (int i = 0; i < 100; i++) {
    char copy[4096];
    strncpy(copy, t, sizeof copy - 1);
    fill_template(copy);
    if (mkdir(copy, 0700) == 0) {
      strcpy(t, copy);
      return t;
    }
    if (errno != EEXIST) return 0;
  }
  return 0;
}

char *mktemp(char *t) {
  fill_template(t);
  return t;
}

int link(const char *a, const char *b) { (void)a; (void)b; return fail(ENOTSUP); }

int utimes(const char *path, const struct timeval tv[2]) {
  (void)tv;
  struct stat st;
  return stat(path, &st);
}

int __libsa_fd_data(int fd, const char **data, size_t *size) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  int ok = f && f->n->type == T_REG;
  if (ok) {
    *data = bytes(f->n);
    *size = f->n->size;
  }
  pthread_mutex_unlock(&lock);
  return ok;
}

int __libsa_fd_console(int fd) {
  pthread_mutex_lock(&lock);
  file *f = get(fd);
  int r = f ? f->n->type == T_CON : -1;
  pthread_mutex_unlock(&lock);
  return r;
}
