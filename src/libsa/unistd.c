#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <sys/ioctl.h>
#include <sys/file.h>
#include <termios.h>
#include <dirent.h>
#include <pwd.h>
#include <spawn.h>
#include <dlfcn.h>
#include <poll.h>
#include <elf.h>
#include "libsa.h"

static int console(int fd) { return fd >= 0 && fd <= 2; }

#define KERNEL_PATH "/System/Library/Kernels/kernel"
#define FIRST_FILE 3
#define MAX_FILES 8

static struct { int open; uint64_t pos; } kfiles[MAX_FILES];
static uint64_t kimage[2];

static int kfile(int fd) { return fd >= FIRST_FILE && fd < FIRST_FILE + MAX_FILES && kfiles[fd - FIRST_FILE].open; }

static const char *kernel_bytes(void) {
  if (!kimage[0]) __machdep(MACHDEP_kernel_file, (long)kimage);
  return (const char *)kimage[0];
}

ssize_t read(int fd, void *buf, size_t n) {
  if (kfile(fd)) {
    const char *k = kernel_bytes();
    uint64_t pos = kfiles[fd - FIRST_FILE].pos;
    if (pos >= kimage[1]) return 0;
    if (n > kimage[1] - pos) n = kimage[1] - pos;
    memcpy(buf, k + pos, n);
    kfiles[fd - FIRST_FILE].pos += n;
    return (ssize_t)n;
  }
  if (!console(fd)) { errno = EBADF; return -1; }
  return __syscall(SYS_read, 0, (long)buf, (long)n, 0, 0, 0);
}

ssize_t write(int fd, const void *buf, size_t n) {
  if (!console(fd)) { errno = EBADF; return -1; }
  return __syscall(SYS_write, fd == 0 ? 1 : fd, (long)buf, (long)n, 0, 0, 0);
}

ssize_t pread(int fd, void *b, size_t n, off_t o) { (void)fd; (void)b; (void)n; (void)o; errno = ESPIPE; return -1; }
ssize_t pwrite(int fd, const void *b, size_t n, off_t o) { (void)fd; (void)b; (void)n; (void)o; errno = ESPIPE; return -1; }
int close(int fd) {
  if (kfile(fd)) { kfiles[fd - FIRST_FILE].open = 0; return 0; }
  if (console(fd)) return 0;
  errno = EBADF;
  return -1;
}

off_t lseek(int fd, off_t o, int w) {
  if (kfile(fd)) {
    kernel_bytes();
    int64_t base = w == SEEK_SET ? 0 : w == SEEK_CUR ? (int64_t)kfiles[fd - FIRST_FILE].pos : (int64_t)kimage[1];
    if (base + o < 0) { errno = EINVAL; return -1; }
    kfiles[fd - FIRST_FILE].pos = (uint64_t)(base + o);
    return (off_t)(base + o);
  }
  errno = console(fd) ? ESPIPE : EBADF;
  return -1;
}

void _exit(int code) {
  __syscall(SYS_exit, code, 0, 0, 0, 0, 0);
  for (;;) {}
}

int open(const char *path, int flags, ...) {
  (void)flags;
  if (!strcmp(path, "/dev/tty") || !strcmp(path, "/dev/console")) return 0;
  if (!strcmp(path, KERNEL_PATH))
    for (int i = 0; i < MAX_FILES; i++)
      if (!kfiles[i].open) {
        kfiles[i].open = 1;
        kfiles[i].pos = 0;
        return FIRST_FILE + i;
      }
  errno = ENOENT;
  return -1;
}

int openat(int dir, const char *path, int flags, ...) { (void)dir; return open(path, flags); }
int creat(const char *path, mode_t mode) { (void)path; (void)mode; errno = EROFS; return -1; }

int fcntl(int fd, int cmd, ...) {
  if (!console(fd)) { errno = EBADF; return -1; }
  if (cmd == F_GETFL) return O_RDWR;
  if (cmd == F_GETFD) return 0;
  return 0;
}

static void console_stat(struct stat *st, int fd) {
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFCHR | 0620;
  st->st_rdev = 0x500 + fd;
  st->st_ino = 3 + fd;
  st->st_nlink = 1;
  st->st_blksize = 1024;
}

static void kernel_stat(struct stat *st) {
  kernel_bytes();
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFREG | 0555;
  st->st_size = (off_t)kimage[1];
  st->st_nlink = 1;
  st->st_ino = 100;
  st->st_blksize = 4096;
}

int fstat(int fd, struct stat *st) {
  if (kfile(fd)) { kernel_stat(st); return 0; }
  if (!console(fd)) { errno = EBADF; return -1; }
  console_stat(st, fd);
  return 0;
}

static int root_stat(const char *path, struct stat *st) {
  if (!strcmp(path, KERNEL_PATH)) { kernel_stat(st); return 0; }
  if (strcmp(path, "/") && strcmp(path, ".")) { errno = ENOENT; return -1; }
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFDIR | 0755;
  st->st_nlink = 2;
  st->st_ino = 2;
  return 0;
}

int stat(const char *path, struct stat *st) { return root_stat(path, st); }
int lstat(const char *path, struct stat *st) { return root_stat(path, st); }
int isatty(int fd) { return console(fd); }
int dup(int fd) { (void)fd; errno = EMFILE; return -1; }
int dup2(int a, int b) { return a == b ? b : (errno = EBADF, -1); }
int pipe(int fds[2]) { (void)fds; errno = ENOSYS; return -1; }
pid_t getpid(void) { return 1; }
pid_t getppid(void) { return 0; }
pid_t getpgrp(void) { return 1; }
int setpgid(pid_t a, pid_t b) { (void)a; (void)b; return 0; }
pid_t setsid(void) { return 1; }
int setpgrp(void) { return 0; }
pid_t tcgetpgrp(int fd) { (void)fd; return 1; }
int tcsetpgrp(int fd, pid_t p) { (void)fd; (void)p; return 0; }
uid_t getuid(void) { return 0; }
uid_t geteuid(void) { return 0; }
gid_t getgid(void) { return 0; }
gid_t getegid(void) { return 0; }

long sysconf(int name) {
  switch (name) {
  case _SC_PAGESIZE: return 4096;
  case _SC_NPROCESSORS_ONLN: return 1;
  case _SC_CLK_TCK: return 100;
  default: errno = EINVAL; return -1;
  }
}

int getpagesize(void) { return 4096; }
int getdtablesize(void) { return 64; }
int access(const char *path, int mode) { struct stat st; (void)mode; return stat(path, &st); }
int unlink(const char *p) { (void)p; errno = ENOENT; return -1; }
int rmdir(const char *p) { (void)p; errno = ENOENT; return -1; }
int chdir(const char *p) { struct stat st; return stat(p, &st); }
int fchdir(int fd) { (void)fd; errno = EBADF; return -1; }
int mkdir(const char *p, mode_t m) { (void)p; (void)m; errno = EROFS; return -1; }
int chmod(const char *p, mode_t m) { (void)p; (void)m; errno = EROFS; return -1; }
int fchmod(int fd, mode_t m) { (void)fd; (void)m; errno = EROFS; return -1; }
int chown(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; errno = EROFS; return -1; }
mode_t umask(mode_t m) { (void)m; return 022; }
int mkfifo(const char *p, mode_t m) { (void)p; (void)m; errno = EROFS; return -1; }
ssize_t readlink(const char *p, char *b, size_t n) { (void)p; (void)b; (void)n; errno = EINVAL; return -1; }
int symlink(const char *a, const char *b) { (void)a; (void)b; errno = EROFS; return -1; }
int link(const char *a, const char *b) { (void)a; (void)b; errno = EROFS; return -1; }
int truncate(const char *p, off_t n) { (void)p; (void)n; errno = EROFS; return -1; }
int ftruncate(int fd, off_t n) { (void)fd; (void)n; errno = EINVAL; return -1; }
int fsync(int fd) { (void)fd; return 0; }
int flock(int fd, int op) { (void)fd; (void)op; return 0; }

char *getcwd(char *buf, size_t n) {
  if (!buf) return strdup("/");
  if (n < 2) { errno = ERANGE; return 0; }
  strcpy(buf, "/");
  return buf;
}

pid_t fork(void) { errno = ENOSYS; return -1; }
int execv(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
int execve(const char *p, char *const a[], char *const e[]) { (void)p; (void)a; (void)e; errno = ENOSYS; return -1; }
int execvp(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
pid_t wait(int *s) { (void)s; errno = ECHILD; return -1; }
pid_t waitpid(pid_t p, int *s, int o) { (void)p; (void)s; (void)o; errno = ECHILD; return -1; }
char *ttyname(int fd) { return console(fd) ? "/dev/console" : 0; }

int gethostname(char *b, size_t n) {
  strncpy(b, "finch", n);
  return 0;
}

int uname(struct utsname *u) {
  memset(u, 0, sizeof *u);
  strcpy(u->sysname, "finch");
  strcpy(u->nodename, "finch");
  strcpy(u->release, "0.1");
  strcpy(u->version, "finch Kernel Version 0.1");
  strcpy(u->machine, "x86_64");
  return 0;
}

int getrusage(int who, struct rusage *r) { (void)who; memset(r, 0, sizeof *r); return 0; }

int getrlimit(int res, struct rlimit *r) {
  r->rlim_cur = r->rlim_max = res == RLIMIT_STACK ? 8ul << 20 : res == RLIMIT_NOFILE ? 64 : RLIM_INFINITY;
  return 0;
}

int setrlimit(int res, const struct rlimit *r) { (void)res; (void)r; return 0; }
int getpriority(int w, id_t i) { (void)w; (void)i; return 0; }
int setpriority(int w, id_t i, int p) { (void)w; (void)i; (void)p; return 0; }

int ioctl(int fd, unsigned long req, ...) {
  if (!console(fd)) { errno = EBADF; return -1; }
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
  errno = ENOTTY;
  return -1;
}

int tcgetattr(int fd, struct termios *t) { (void)fd; memset(t, 0, sizeof *t); return 0; }
int tcsetattr(int fd, int a, const struct termios *t) { (void)fd; (void)a; (void)t; return 0; }
int close_range(unsigned a, unsigned b, int flags) { (void)a; (void)b; (void)flags; return 0; }
char *ptsname(int fd) { (void)fd; errno = ENOSYS; return 0; }
int grantpt(int fd) { (void)fd; errno = ENOSYS; return -1; }
int unlockpt(int fd) { (void)fd; errno = ENOSYS; return -1; }

DIR *opendir(const char *p) { (void)p; errno = ENOENT; return 0; }
DIR *fdopendir(int fd) { (void)fd; errno = EBADF; return 0; }
struct dirent *readdir(DIR *d) { (void)d; return 0; }
struct dirent *readdir64(DIR *d) { return readdir(d); }
int closedir(DIR *d) { (void)d; return 0; }
int dirfd(DIR *d) { (void)d; return -1; }

static struct passwd root = {"root", "", 0, 0, "root", "/", "/bin/sh"};
struct passwd *getpwuid(uid_t u) { return u == 0 ? &root : 0; }
struct passwd *getpwnam(const char *n) { return strcmp(n, "root") ? 0 : &root; }

int posix_spawn(pid_t *p, const char *path, const posix_spawn_file_actions_t *f, const posix_spawnattr_t *a,
                char *const argv[], char *const envp[]) {
  (void)p; (void)path; (void)f; (void)a; (void)argv; (void)envp;
  return ENOSYS;
}
int posix_spawnp(pid_t *p, const char *path, const posix_spawn_file_actions_t *f, const posix_spawnattr_t *a,
                 char *const argv[], char *const envp[]) {
  return posix_spawn(p, path, f, a, argv, envp);
}
int posix_spawnattr_init(posix_spawnattr_t *a) { memset(a, 0, sizeof *a); return 0; }
int posix_spawnattr_destroy(posix_spawnattr_t *a) { (void)a; return 0; }
int posix_spawnattr_setflags(posix_spawnattr_t *a, short f) { a->flags = f; return 0; }
int posix_spawnattr_setpgroup(posix_spawnattr_t *a, pid_t p) { a->pgroup = p; return 0; }
int posix_spawnattr_setsigmask(posix_spawnattr_t *a, const sigset_t *s) { a->mask = *s; return 0; }
int posix_spawnattr_setsigdefault(posix_spawnattr_t *a, const sigset_t *s) { a->def = *s; return 0; }
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *f) { memset(f, 0, sizeof *f); return 0; }
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *f) { (void)f; return 0; }
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *f, int a, int b) { (void)f; (void)a; (void)b; return 0; }
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *f, int fd, const char *p, int o, mode_t m) {
  (void)f; (void)fd; (void)p; (void)o; (void)m;
  return 0;
}
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *f, int fd) { (void)f; (void)fd; return 0; }
int posix_spawn_file_actions_addclosefrom_np(posix_spawn_file_actions_t *f, int fd) { (void)f; (void)fd; return 0; }

static char dl_error[] = "no dynamic loading on finch";
static int runtime_handle;

void *dlopen(const char *p, int f) {
  (void)f;
  if (!p || !strcmp(p, KERNEL_PATH)) return &runtime_handle;
  return 0;
}

int dlclose(void *h) { (void)h; return 0; }
char *dlerror(void) { return dl_error; }

static const Elf64_Sym *symbols;
static const char *symbol_names;
static size_t nsymbols;

static void load_symbols(void) {
  const char *k = kernel_bytes();
  const Elf64_Ehdr *eh = (const Elf64_Ehdr *)k;
  const Elf64_Shdr *sh = (const Elf64_Shdr *)(k + eh->e_shoff);
  for (int i = 0; i < eh->e_shnum; i++)
    if (sh[i].sh_type == SHT_SYMTAB) {
      symbols = (const Elf64_Sym *)(k + sh[i].sh_offset);
      nsymbols = sh[i].sh_size / sizeof(Elf64_Sym);
      symbol_names = k + sh[sh[i].sh_link].sh_offset;
    }
}

void *dlsym(void *h, const char *name) {
  if (h && h != &runtime_handle) return 0;
  if (!symbols) load_symbols();
  for (size_t i = 0; i < nsymbols; i++)
    if (symbols[i].st_shndx != SHN_UNDEF && (symbols[i].st_info >> 4) == STB_GLOBAL &&
        !strcmp(symbol_names + symbols[i].st_name, name))
      return (void *)symbols[i].st_value;
  return 0;
}

int dladdr(const void *a, Dl_info *info) {
  if (!symbols) load_symbols();
  const Elf64_Sym *best = 0;
  for (size_t i = 0; i < nsymbols; i++)
    if (symbols[i].st_shndx != SHN_UNDEF && symbols[i].st_value <= (uint64_t)a &&
        (!best || symbols[i].st_value > best->st_value))
      best = &symbols[i];
  if (!best) return 0;
  info->dli_fname = KERNEL_PATH;
  info->dli_fbase = 0;
  info->dli_sname = symbol_names + best->st_name;
  info->dli_saddr = (void *)best->st_value;
  return 1;
}

int h_errno;

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  if (!(flags & MAP_ANONYMOUS)) {
    if (!kfile(fd)) { errno = ENODEV; return MAP_FAILED; }
    void *at = mmap(addr, len, PROT_READ | PROT_WRITE, (flags & MAP_FIXED) | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (at == MAP_FAILED) return at;
    const char *k = kernel_bytes();
    size_t n = (uint64_t)off >= kimage[1] ? 0 : len < kimage[1] - off ? len : kimage[1] - off;
    memcpy(at, k + off, n);
    if (prot != (PROT_READ | PROT_WRITE)) mprotect(at, len, prot);
    return at;
  }
  long darwin = 0x1000 | ((flags & MAP_FIXED) ? 0x10 : 0) | ((flags & MAP_PRIVATE) ? 0x2 : 0) | ((flags & MAP_SHARED) ? 0x1 : 0);
  long r = __syscall(SYS_mmap, (long)addr, (long)len, prot, darwin, fd, off);
  return r == -1 ? MAP_FAILED : (void *)r;
}

int munmap(void *addr, size_t len) { return (int)__syscall(SYS_munmap, (long)addr, (long)len, 0, 0, 0, 0); }
int mprotect(void *addr, size_t len, int prot) { return (int)__syscall(SYS_mprotect, (long)addr, (long)len, prot, 0, 0, 0); }
int madvise(void *a, size_t n, int adv) { return (int)__syscall(SYS_madvise, (long)a, (long)n, adv, 0, 0, 0); }
int msync(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int mlock(const void *a, size_t n) { (void)a; (void)n; return 0; }

long syscall(long n, ...) {
  va_list ap;
  va_start(ap, n);
  long a = va_arg(ap, long), b = va_arg(ap, long), c = va_arg(ap, long);
  long d = va_arg(ap, long), e = va_arg(ap, long), f = va_arg(ap, long);
  va_end(ap);
  switch (n) {
  case 9: return (long)mmap((void *)a, b, (int)c, (int)d, (int)e, f);
  case 10: return mprotect((void *)a, b, (int)c);
  case 11: return munmap((void *)a, b);
  case 186: return 1;
  default: errno = ENOSYS; return -1;
  }
}

int poll(struct pollfd *fds, nfds_t n, int timeout) {
  int ready = 0;
  for (;;) {
    for (nfds_t i = 0; i < n; i++) {
      fds[i].revents = 0;
      if (fds[i].fd == 1 || fds[i].fd == 2) fds[i].revents = fds[i].events & POLLOUT;
      if (fds[i].fd == 0 && (fds[i].events & POLLIN) && __machdep(MACHDEP_console_ready, 0))
        fds[i].revents |= POLLIN;
      if (fds[i].revents) ready++;
    }
    if (ready || timeout == 0) return ready;
    __asm__ volatile("pause");
  }
}
