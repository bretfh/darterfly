#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <time.h>
#include "libsa.h"

enum {
  VFS_open = 1, VFS_close, VFS_read, VFS_write, VFS_pread, VFS_pwrite, VFS_lseek, VFS_stat, VFS_lstat, VFS_fstat,
  VFS_readlink, VFS_symlink, VFS_mkdir, VFS_rmdir, VFS_unlink, VFS_rename, VFS_chdir, VFS_fchdir, VFS_getcwd,
  VFS_realpath, VFS_chmod, VFS_fchmod, VFS_chown, VFS_fchown, VFS_truncate, VFS_ftruncate, VFS_dup, VFS_dup2,
  VFS_fcntl, VFS_readdir, VFS_link, VFS_utimes, VFS_fsync, VFS_umask, VFS_pipe, VFS_spawn, VFS_waitpid,
  VFS_socket, VFS_bind, VFS_listen, VFS_accept, VFS_connect, VFS_getsockname, VFS_getpeername, VFS_shutdown,
  VFS_recvfrom, VFS_sendto, VFS_resolve
};

typedef long (*vfs_entry)(long op, long a, long b, long c, long d);
static vfs_entry vfs;

static int boot_first;

void __libsa_vfs_register(vfs_entry entry) { vfs = entry; }

void __libsa_vfs_boot_first(void) { boot_first = 1; }

#define KERNEL_PATH "/System/Library/Kernels/kernel"
#define CORE_PATH "/System/Library/Kernels/darterfly.core"
#define SAVE_PATH "/System/Library/Kernels/saved.core"
#define SAVE_BASE 0x0000300000000000ul
#define SAVE_SPACE (16ul << 30)
#define KERNEL_FD 1000
#define KERNEL_FDS 8

struct boot_file { const char *data; size_t size; };
static struct boot_file kernel_file, core_file, saved_file;
static int saving;
static struct { int open; off_t off; struct boot_file *file; } kfds[KERNEL_FDS];

static long ret(long r) {
  if (r < 0) {
    errno = (int)-r;
    return -1;
  }
  return r;
}

static long call(int op, long a, long b, long c, long d) {
  if (!vfs) return op == VFS_getcwd || op == VFS_realpath || op == VFS_stat || op == VFS_lstat || op == VFS_open ? -ENOENT : -EBADF;
  return vfs(op, a, b, c, d);
}

int __libsa_run_stdin(void);
static int console(int fd) { return fd >= 0 && fd <= 2 && !(fd == 0 && __libsa_run_stdin()); }
static int kfd(int fd) { return fd >= KERNEL_FD && fd < KERNEL_FD + KERNEL_FDS && kfds[fd - KERNEL_FD].open; }

static struct boot_file *boot_file(const char *path) {
  struct boot_file *f = !strcmp(path, KERNEL_PATH) ? &kernel_file : !strcmp(path, CORE_PATH) ? &core_file : 0;
  if (!f) return 0;
  if (!f->data) {
    uint64_t k[2] = {0, 0};
    __machdep(f == &kernel_file ? MACHDEP_kernel_file : MACHDEP_core_file, (long)k, 0);
    f->data = (const char *)k[0];
    f->size = k[1];
  }
  return f->data ? f : 0;
}

int __libsa_core_range(uint64_t *data, uint64_t *size) {
  struct boot_file *f = boot_file(CORE_PATH);
  if (!f) return 0;
  *data = (uint64_t)f->data;
  *size = f->size;
  return 1;
}

void __libsa_run_core(const char *data, size_t size) {
  core_file.data = data;
  core_file.size = size;
}

int __libsa_saved_core(uint64_t *core, uint64_t *size) {
  if (!saved_file.size || saving) return 0;
  *core = (uint64_t)saved_file.data;
  *size = saved_file.size;
  return 1;
}

static int kernel_open(struct boot_file *file) {
  for (int i = 0; i < KERNEL_FDS; i++)
    if (!kfds[i].open) {
      kfds[i].open = 1;
      kfds[i].off = 0;
      kfds[i].file = file;
      return KERNEL_FD + i;
    }
  errno = EMFILE;
  return -1;
}

static ssize_t kernel_read(int fd, void *buf, size_t n, off_t *off) {
  struct boot_file *f = kfds[fd - KERNEL_FD].file;
  if ((size_t)*off >= f->size) return 0;
  if (n > f->size - *off) n = f->size - *off;
  memcpy(buf, f->data + *off, n);
  *off += n;
  return (ssize_t)n;
}

const char *__libsa_boot_data(int fd, size_t *size) {
  if (!kfd(fd)) return 0;
  *size = kfds[fd - KERNEL_FD].file->size;
  return kfds[fd - KERNEL_FD].file->data;
}

static void kernel_stat(struct boot_file *f, struct stat *st) {
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFREG | 0555;
  st->st_nlink = 1;
  st->st_size = (off_t)f->size;
  st->st_blksize = 4096;
}

static void console_stat(struct stat *st) {
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFCHR | 0620;
  st->st_nlink = 1;
  st->st_rdev = 0x501;
  st->st_blksize = 4096;
}

int open(const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = (flags & O_CREAT) ? va_arg(ap, mode_t) : 0;
  va_end(ap);
  if (!strcmp(path, SAVE_PATH)) {
    if (!saved_file.data) {
      void *at = mmap((void *)SAVE_BASE, SAVE_SPACE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
      if (at == MAP_FAILED) return -1;
      saved_file.data = at;
    }
    saved_file.size = 0;
    saving++;
    return kernel_open(&saved_file);
  }
  struct boot_file *file = vfs && !boot_first ? 0 : boot_file(path);
  if (file) return kernel_open(file);
  return (int)ret(call(VFS_open, (long)path, flags, mode, 0));
}

int openat(int dir, const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = (flags & O_CREAT) ? va_arg(ap, mode_t) : 0;
  va_end(ap);
  (void)dir;
  return open(path, flags, mode);
}

int creat(const char *path, mode_t mode) { return open(path, O_WRONLY | O_CREAT | O_TRUNC, mode); }

int close(int fd) {
  if (console(fd)) return 0;
  if (kfd(fd)) {
    if (kfds[fd - KERNEL_FD].file == &saved_file) saving--;
    kfds[fd - KERNEL_FD].open = 0;
    return 0;
  }
  return (int)ret(call(VFS_close, fd, 0, 0, 0));
}

ssize_t read(int fd, void *buf, size_t n) {
  if (console(fd)) return __syscall(SYS_read, 0, (long)buf, (long)n, 0, 0, 0);
  if (kfd(fd)) return kernel_read(fd, buf, n, &kfds[fd - KERNEL_FD].off);
  return ret(call(VFS_read, fd, (long)buf, (long)n, 0));
}

static ssize_t saved_write(int fd, const void *buf, size_t n, off_t *off) {
  if ((size_t)*off + n > SAVE_SPACE) return ret(-ENOSPC);
  memcpy((char *)saved_file.data + *off, buf, n);
  *off += n;
  if ((size_t)*off > saved_file.size) saved_file.size = *off;
  (void)fd;
  return (ssize_t)n;
}

ssize_t write(int fd, const void *buf, size_t n) {
  if (console(fd)) return __syscall(SYS_write, 1, (long)buf, (long)n, 0, 0, 0);
  if (kfd(fd) && kfds[fd - KERNEL_FD].file == &saved_file) return saved_write(fd, buf, n, &kfds[fd - KERNEL_FD].off);
  return ret(call(VFS_write, fd, (long)buf, (long)n, 0));
}

ssize_t pread(int fd, void *buf, size_t n, off_t off) {
  if (console(fd)) return ret(-ESPIPE);
  if (kfd(fd)) return kernel_read(fd, buf, n, &off);
  return ret(call(VFS_pread, fd, (long)buf, (long)n, off));
}

ssize_t pwrite(int fd, const void *buf, size_t n, off_t off) {
  if (console(fd)) return ret(-ESPIPE);
  if (kfd(fd) && kfds[fd - KERNEL_FD].file == &saved_file) return saved_write(fd, buf, n, &off);
  return ret(call(VFS_pwrite, fd, (long)buf, (long)n, off));
}

off_t lseek(int fd, off_t off, int whence) {
  if (console(fd)) return ret(-ESPIPE);
  if (kfd(fd)) {
    off_t *at = &kfds[fd - KERNEL_FD].off;
    off_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? *at : (off_t)kfds[fd - KERNEL_FD].file->size;
    if (base + off < 0) return ret(-EINVAL);
    return *at = base + off;
  }
  return ret(call(VFS_lseek, fd, off, whence, 0));
}

int stat(const char *path, struct stat *st) {
  struct boot_file *file = vfs && !boot_first ? 0 : boot_file(path);
  if (file) {
    kernel_stat(file, st);
    return 0;
  }
  return (int)ret(call(VFS_stat, (long)path, (long)st, 0, 0));
}

int lstat(const char *path, struct stat *st) {
  if (!vfs || (boot_first && boot_file(path))) return stat(path, st);
  return (int)ret(call(VFS_lstat, (long)path, (long)st, 0, 0));
}

int fstat(int fd, struct stat *st) {
  if (console(fd)) {
    console_stat(st);
    return 0;
  }
  if (kfd(fd)) {
    kernel_stat(kfds[fd - KERNEL_FD].file, st);
    return 0;
  }
  return (int)ret(call(VFS_fstat, fd, (long)st, 0, 0));
}

ssize_t readlink(const char *path, char *buf, size_t size) { return ret(call(VFS_readlink, (long)path, (long)buf, (long)size, 0)); }
int symlink(const char *target, const char *path) { return (int)ret(call(VFS_symlink, (long)target, (long)path, 0, 0)); }
int link(const char *a, const char *b) { return (int)ret(call(VFS_link, (long)a, (long)b, 0, 0)); }
int mkdir(const char *path, mode_t mode) { return (int)ret(call(VFS_mkdir, (long)path, mode, 0, 0)); }
int rmdir(const char *path) { return (int)ret(call(VFS_rmdir, (long)path, 0, 0, 0)); }
int unlink(const char *path) { return (int)ret(call(VFS_unlink, (long)path, 0, 0, 0)); }
int rename(const char *from, const char *to) { return (int)ret(call(VFS_rename, (long)from, (long)to, 0, 0)); }
int chdir(const char *path) { return (int)ret(call(VFS_chdir, (long)path, 0, 0, 0)); }
int fchdir(int fd) { return (int)ret(call(VFS_fchdir, fd, 0, 0, 0)); }
int chmod(const char *path, mode_t m) { return (int)ret(call(VFS_chmod, (long)path, m, 0, 0)); }
int fchmod(int fd, mode_t m) { return (int)ret(call(VFS_fchmod, fd, m, 0, 0)); }
int chown(const char *path, uid_t u, gid_t g) { return (int)ret(call(VFS_chown, (long)path, (long)(int)u, (long)(int)g, 0)); }
int lchown(const char *path, uid_t u, gid_t g) { return chown(path, u, g); }
int fchown(int fd, uid_t u, gid_t g) { return (int)ret(call(VFS_fchown, fd, (long)(int)u, (long)(int)g, 0)); }
int truncate(const char *path, off_t len) { return (int)ret(call(VFS_truncate, (long)path, len, 0, 0)); }
int ftruncate(int fd, off_t len) { return (int)ret(call(VFS_ftruncate, fd, len, 0, 0)); }
int fsync(int fd) { return console(fd) ? 0 : (int)ret(call(VFS_fsync, fd, 0, 0, 0)); }
int fdatasync(int fd) { return fsync(fd); }
void sync(void) {}
int pipe(int fds[2]) { return (int)ret(call(VFS_pipe, (long)fds, 0, 0, 0)); }

int __libsa_spawn(char *program, char *argv[], int sin, int sout, int serr, int search, char *envp[], char *pwd) {
  long args[8] = {(long)program, (long)argv, sin, sout, serr, (long)envp, (long)pwd, search};
  return (int)ret(call(VFS_spawn, (long)args, 0, 0, 0));
}

int socket(int domain, int type, int protocol) { return (int)ret(call(VFS_socket, domain, type, protocol, 0)); }
int bind(int fd, const void *addr, unsigned len) { return (int)ret(call(VFS_bind, fd, (long)addr, len, 0)); }
int listen(int fd, int backlog) { return (int)ret(call(VFS_listen, fd, backlog, 0, 0)); }
int accept(int fd, void *addr, unsigned *len) { return (int)ret(call(VFS_accept, fd, (long)addr, (long)len, 0)); }
int connect(int fd, const void *addr, unsigned len) { return (int)ret(call(VFS_connect, fd, (long)addr, len, 0)); }
int getsockname(int fd, void *addr, unsigned *len) { return (int)ret(call(VFS_getsockname, fd, (long)addr, (long)len, 0)); }
int getpeername(int fd, void *addr, unsigned *len) { return (int)ret(call(VFS_getpeername, fd, (long)addr, (long)len, 0)); }
int shutdown(int fd, int how) { return (int)ret(call(VFS_shutdown, fd, how, 0, 0)); }

long recvfrom(int fd, void *buf, size_t n, int flags, void *addr, unsigned *len) {
  long args[4] = {(long)buf, (long)n, (long)addr, (long)len};
  return ret(call(VFS_recvfrom, fd, (long)args, flags, 0));
}

long sendto(int fd, const void *buf, size_t n, int flags, const void *addr, unsigned len) {
  long args[4] = {(long)buf, (long)n, (long)addr, len};
  return ret(call(VFS_sendto, fd, (long)args, flags, 0));
}

long recv(int fd, void *buf, size_t n, int flags) { return recvfrom(fd, buf, n, flags, 0, 0); }
long send(int fd, const void *buf, size_t n, int flags) { return sendto(fd, buf, n, flags, 0, 0); }

int setsockopt(int fd, int level, int name, const void *value, unsigned len) {
  (void)fd; (void)level; (void)name; (void)value; (void)len;
  return 0;
}

int getsockopt(int fd, int level, int name, void *value, unsigned *len) {
  (void)fd; (void)level; (void)name;
  if (value && len && *len >= sizeof(int)) {
    *(int *)value = 0;
    *len = sizeof(int);
  }
  return 0;
}

struct addrinfo {
  int ai_flags, ai_family, ai_socktype, ai_protocol;
  unsigned ai_addrlen;
  unsigned char *ai_addr;
  char *ai_canonname;
  struct addrinfo *ai_next;
};

int getaddrinfo(const char *node, const char *service, const void *hints_, void **res) {
  const struct addrinfo *hints = hints_;
  int family = hints ? hints->ai_family : 0;
  unsigned char addrs[8][16];
  int families[8];
  long n;
  if (node) n = call(VFS_resolve, (long)node, (long)addrs, (long)families, 8 | (family << 8));
  else {
    n = 1;
    families[0] = family == 10 ? 10 : 2;
    memset(addrs[0], 0, 16);
  }
  if (n <= 0) return -2;
  int port = service ? atoi(service) : 0;
  struct addrinfo *head = 0, **tail = &head;
  for (long i = 0; i < n; i++) {
    struct addrinfo *ai = calloc(1, sizeof *ai);
    unsigned char *sa = calloc(1, 28);
    sa[0] = (unsigned char)families[i];
    sa[2] = (unsigned char)(port >> 8);
    sa[3] = (unsigned char)port;
    if (families[i] == 2) {
      memcpy(sa + 4, addrs[i], 4);
      ai->ai_addrlen = 16;
    } else {
      memcpy(sa + 8, addrs[i], 16);
      ai->ai_addrlen = 28;
    }
    ai->ai_family = families[i];
    ai->ai_socktype = hints && hints->ai_socktype ? hints->ai_socktype : 1;
    ai->ai_protocol = hints ? hints->ai_protocol : 0;
    ai->ai_addr = sa;
    *tail = ai;
    tail = &ai->ai_next;
  }
  *res = head;
  return 0;
}

void freeaddrinfo(void *p) {
  struct addrinfo *ai = p;
  while (ai) {
    struct addrinfo *next = ai->ai_next;
    free(ai->ai_addr);
    free(ai);
    ai = next;
  }
}

const char *gai_strerror(int e) { return e == -2 ? "Name or service not known" : "Name resolution failed"; }

pid_t waitpid(pid_t pid, int *status, int options) {
  return (pid_t)ret(call(VFS_waitpid, pid, (long)status, options, 0));
}
int dup(int fd) { return (int)ret(call(VFS_dup, fd, 0, 0, 0)); }
int dup2(int a, int b) { return (int)ret(call(VFS_dup2, a, b, 0, 0)); }

mode_t umask(mode_t m) {
  long r = call(VFS_umask, m, 0, 0, 0);
  return r < 0 ? 022 : (mode_t)r;
}

int utimes(const char *path, const struct timeval tv[2]) { return (int)ret(call(VFS_utimes, (long)path, (long)tv, 0, 0)); }

int access(const char *path, int mode) {
  struct stat st;
  (void)mode;
  return stat(path, &st);
}

int remove(const char *path) {
  struct stat st;
  if (lstat(path, &st) < 0) return -1;
  return S_ISDIR(st.st_mode) ? rmdir(path) : unlink(path);
}

int fcntl(int fd, int cmd, ...) {
  va_list ap;
  va_start(ap, cmd);
  long arg = va_arg(ap, long);
  va_end(ap);
  if (console(fd) || kfd(fd)) return cmd == F_GETFL ? (console(fd) ? O_RDWR : O_RDONLY) : 0;
  return (int)ret(call(VFS_fcntl, fd, cmd, arg, 0));
}

int isatty(int fd) {
  if (console(fd)) return 1;
  errno = ENOTTY;
  return 0;
}

int ioctl(int fd, unsigned long req, ...) {
  if (!console(fd)) return (int)ret(-ENOTTY);
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
  return (int)ret(-ENOTTY);
}

char *ttyname(int fd) { return console(fd) ? "/dev/console" : 0; }

char *getcwd(char *buf, size_t n) {
  char tmp[4096] = "/";
  if (vfs && ret(call(VFS_getcwd, (long)tmp, sizeof tmp, 0, 0)) < 0) return 0;
  if (!buf) return strdup(tmp);
  if (strlen(tmp) + 1 > n) {
    errno = ERANGE;
    return 0;
  }
  return strcpy(buf, tmp);
}

char *realpath(const char *path, char *out) {
  char tmp[4096];
  if (ret(call(VFS_realpath, (long)path, (long)tmp, sizeof tmp, 0)) < 0) return 0;
  return out ? strcpy(out, tmp) : strdup(tmp);
}

struct __DIR { int fd; long at; struct dirent ent; };

static DIR *open_dir(int fd) {
  if (fd < 0) return 0;
  DIR *d = calloc(1, sizeof *d);
  d->fd = fd;
  return d;
}

DIR *opendir(const char *path) { return open_dir(open(path, O_RDONLY | O_DIRECTORY)); }
DIR *fdopendir(int fd) { return open_dir(fd); }

struct dirent *readdir(DIR *d) {
  long r = ret(call(VFS_readdir, d->fd, d->at, (long)&d->ent, 0));
  if (r <= 0) return 0;
  d->at++;
  return &d->ent;
}

struct dirent *readdir64(DIR *d) { return readdir(d); }

int closedir(DIR *d) {
  close(d->fd);
  free(d);
  return 0;
}

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
    copy[sizeof copy - 1] = 0;
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
    copy[sizeof copy - 1] = 0;
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

int __libsa_fd_console(int fd) { return console(fd) ? 1 : fd >= 0 ? 0 : -1; }
