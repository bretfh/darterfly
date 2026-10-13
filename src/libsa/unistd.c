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
#include <sys/time.h>
#include <elf.h>
#include "libsa.h"


#define KERNEL_PATH "/System/Library/Kernels/kernel"







void _exit(int code) {
  __syscall(SYS_exit, code, 0, 0, 0, 0, 0);
  for (;;) {}
}








int pipe(int fds[2]) { (void)fds; errno = ENOSYS; return -1; }
pid_t getpid(void) { return 1; }
pid_t getppid(void) { return 0; }
pid_t getpgrp(void) { return 1; }
int setpgid(pid_t a, pid_t b) { (void)a; (void)b; return 0; }
pid_t setsid(void) { return 1; }
int setpgrp(pid_t a, pid_t b) { (void)a; (void)b; return 0; }
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
mode_t umask(mode_t m) { (void)m; return 022; }
int mkfifo(const char *p, mode_t m) { (void)p; (void)m; errno = EROFS; return -1; }
int flock(int fd, int op) { (void)fd; (void)op; return 0; }


pid_t fork(void) { errno = ENOSYS; return -1; }
int execv(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
int execve(const char *p, char *const a[], char *const e[]) { (void)p; (void)a; (void)e; errno = ENOSYS; return -1; }
int execvp(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
pid_t wait(int *s) { (void)s; errno = ECHILD; return -1; }
pid_t waitpid(pid_t p, int *s, int o) { (void)p; (void)s; (void)o; errno = ECHILD; return -1; }

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


int tcgetattr(int fd, struct termios *t) { (void)fd; memset(t, 0, sizeof *t); return 0; }
int tcsetattr(int fd, int a, const struct termios *t) { (void)fd; (void)a; (void)t; return 0; }
int close_range(unsigned a, unsigned b, int flags) { (void)a; (void)b; (void)flags; return 0; }
char *ptsname(int fd) { (void)fd; errno = ENOSYS; return 0; }
int grantpt(int fd) { (void)fd; errno = ENOSYS; return -1; }
int unlockpt(int fd) { (void)fd; errno = ENOSYS; return -1; }


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

static uint64_t kimage[2];

static void load_symbols(void) {
  if (!kimage[0]) __machdep(MACHDEP_kernel_file, (long)kimage, 0);
  const char *k = (const char *)kimage[0];
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

int __libsa_fd_data(int fd, const char **data, size_t *size);
int __libsa_fd_console(int fd);

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  if (!(flags & MAP_ANONYMOUS)) {
    const char *k;
    size_t ksize;
    if (!__libsa_fd_data(fd, &k, &ksize)) { errno = ENODEV; return MAP_FAILED; }
    void *at = mmap(addr, len, PROT_READ | PROT_WRITE, (flags & MAP_FIXED) | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (at == MAP_FAILED) return at;
    size_t n = (uint64_t)off >= ksize ? 0 : len < ksize - off ? len : ksize - off;
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
  case 186: return __syscall(SYS_thread_selfid, 0, 0, 0, 0, 0, 0);
  default: errno = ENOSYS; return -1;
  }
}


int poll(struct pollfd *fds, nfds_t n, int timeout) {
  struct pollfd console[2];
  int ready = 0, nconsole = 0, want_in = 0, want_out = 0;
  for (nfds_t i = 0; i < n; i++) {
    fds[i].revents = 0;
    int c = __libsa_fd_console(fds[i].fd);
    if (c < 0) fds[i].revents = POLLNVAL;
    else if (!c) fds[i].revents = fds[i].events & (POLLIN | POLLOUT);
    else {
      want_in |= fds[i].events & POLLIN;
      want_out |= fds[i].events & POLLOUT;
    }
    if (fds[i].revents) ready++;
  }
  if (want_in) console[nconsole++] = (struct pollfd){0, POLLIN, 0};
  if (want_out) console[nconsole++] = (struct pollfd){1, POLLOUT, 0};
  if (!nconsole) return ready;
  long r = __syscall(SYS_poll, (long)console, nconsole, ready ? 0 : timeout, 0, 0, 0);
  if (r < 0) return ready ? ready : -1;
  for (nfds_t i = 0; i < n; i++)
    if (__libsa_fd_console(fds[i].fd) == 1) {
      for (int j = 0; j < nconsole; j++) fds[i].revents |= console[j].revents & fds[i].events;
      if (fds[i].revents) ready++;
    }
  return ready;
}

#define ENOSYS_STUB(type, name, args) \
  type name args {                    \
    errno = ENOSYS;                   \
    return (type)-1;                  \
  }

int mount(const char *a, const char *b, const char *c, unsigned long d, const void *e) {
  (void)a; (void)b; (void)c; (void)d; (void)e;
  errno = EPERM;
  return -1;
}
int reboot(int how) { __syscall(SYS_exit, how, 0, 0, 0, 0, 0); return 0; }
int tcdrain(int fd) { (void)fd; return 0; }
int tcflow(int fd, int a) { (void)fd; (void)a; return 0; }
int tcflush(int fd, int a) { (void)fd; (void)a; return 0; }
int tcsendbreak(int fd, int a) { (void)fd; (void)a; return 0; }
pid_t tcgetsid(int fd) { (void)fd; return 1; }
speed_t cfgetispeed(const struct termios *t) { return t->c_ispeed; }
speed_t cfgetospeed(const struct termios *t) { return t->c_ospeed; }
int cfsetispeed(struct termios *t, speed_t s) { t->c_ispeed = s; return 0; }
int cfsetospeed(struct termios *t, speed_t s) { t->c_ospeed = s; return 0; }
int chroot(const char *p) { (void)p; errno = EPERM; return -1; }
int lockf(int fd, int cmd, off_t len) { (void)fd; (void)cmd; (void)len; return 0; }
int seteuid(uid_t u) { return u == 0 ? 0 : (errno = EPERM, -1); }
int setuid(uid_t u) { return seteuid(u); }
int setreuid(uid_t a, uid_t b) { (void)a; return seteuid(b == (uid_t)-1 ? 0 : b); }
int setresuid(uid_t a, uid_t b, uid_t c) { (void)a; (void)c; return seteuid(b == (uid_t)-1 ? 0 : b); }
int setfsuid(uid_t u) { (void)u; return 0; }
int setegid(gid_t g) { return g == 0 ? 0 : (errno = EPERM, -1); }
int setgid(gid_t g) { return setegid(g); }
int setregid(gid_t a, gid_t b) { (void)a; return setegid(b == (gid_t)-1 ? 0 : b); }
int setresgid(gid_t a, gid_t b, gid_t c) { (void)a; (void)c; return setegid(b == (gid_t)-1 ? 0 : b); }
int setfsgid(gid_t g) { (void)g; return 0; }
int getresuid(uid_t *a, uid_t *b, uid_t *c) { *a = *b = *c = 0; return 0; }
int getresgid(gid_t *a, gid_t *b, gid_t *c) { *a = *b = *c = 0; return 0; }
unsigned alarm(unsigned s) {
  struct itimerval v = {{0, 0}, {s, 0}}, old;
  setitimer(ITIMER_REAL, &v, &old);
  return (unsigned)old.it_value.tv_sec;
}
pid_t getpgid(pid_t p) { (void)p; return 1; }
pid_t getsid(pid_t p) { (void)p; return 1; }
int pause(void) {
  for (;;) {
    struct timespec t = {1000000, 0};
    if (nanosleep(&t, 0) < 0) return -1;
  }
}
int mlockall(int f) { (void)f; return 0; }
int munlockall(void) { return 0; }
struct passwd *getpwent(void) { return 0; }
void setpwent(void) {}
void endpwent(void) {}
struct group;
struct group *getgrnam(const char *n) { (void)n; return 0; }
struct group *getgrgid(gid_t g) { (void)g; return 0; }
struct group *getgrent(void) { return 0; }
void setgrent(void) {}
void endgrent(void) {}
int utime(const char *p, const void *t) { (void)t; struct stat st; return stat(p, &st); }
void openlog(const char *i, int o, int f) { (void)i; (void)o; (void)f; }
void syslog(int p, const char *f, ...) { (void)p; (void)f; }
void closelog(void) {}
void *getprotobyname(const char *n) { (void)n; return 0; }
void *getprotobynumber(int n) { (void)n; return 0; }
int getprotobyname_r(const char *n, void *a, char *b, size_t l, void **r) { (void)n; (void)a; (void)b; (void)l; *r = 0; return ENOENT; }
int getprotobynumber_r(int n, void *a, char *b, size_t l, void **r) { (void)n; (void)a; (void)b; (void)l; *r = 0; return ENOENT; }
const char *inet_ntop(int af, const void *s, char *d, unsigned n) { (void)af; (void)s; (void)d; (void)n; errno = EAFNOSUPPORT; return 0; }
int inet_pton(int af, const char *s, void *d) { (void)af; (void)s; (void)d; errno = EAFNOSUPPORT; return -1; }
ENOSYS_STUB(int, socket, (int a, int b, int c))
ENOSYS_STUB(int, bind, (int a, const void *b, unsigned c))
ENOSYS_STUB(int, listen, (int a, int b))
ENOSYS_STUB(int, accept, (int a, void *b, unsigned *c))
ENOSYS_STUB(int, getpeername, (int a, void *b, unsigned *c))
ENOSYS_STUB(int, getsockname, (int a, void *b, unsigned *c))
ENOSYS_STUB(int, connect, (int a, const void *b, unsigned c))
ENOSYS_STUB(int, shutdown, (int a, int b))
ENOSYS_STUB(long, recvfrom, (int a, void *b, size_t c, int d, void *e, unsigned *f))
ENOSYS_STUB(long, send, (int a, const void *b, size_t c, int d))
ENOSYS_STUB(long, sendto, (int a, const void *b, size_t c, int d, const void *e, unsigned f))
ENOSYS_STUB(int, setsockopt, (int a, int b, int c, const void *d, unsigned e))
ENOSYS_STUB(int, getsockopt, (int a, int b, int c, void *d, unsigned *e))
int getaddrinfo(const char *a, const char *b, const void *c, void **d) { (void)a; (void)b; (void)c; (void)d; return -2; }
void freeaddrinfo(void *a) { (void)a; }
const char *gai_strerror(int e) { (void)e; return "no networking on finch yet"; }
int getnameinfo(const void *a, unsigned b, char *c, unsigned d, char *e, unsigned f, int g) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g;
  return -2;
}
