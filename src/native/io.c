/* Initial single-threaded native libc subset. No host addresses cross IPC. */
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>

typedef unsigned long word;
extern long native_call(word, const void *, word, void *, word);
static int native_errno;
char **environ;
int *__errno_location(void) { return &native_errno; }
#define LIMIT 4096
#define MAGIC 0x3156534e4644UL

static void bytes_copy(void *to, const void *from, unsigned long n) {
    unsigned char *d = to;
    const unsigned char *s = from;
    while (n--) *d++ = *s++;
}
static long rpc(word op, word a, word b, const void *in, word n,
                void *out, word cap) {
    word request[4 + LIMIT / 8], reply[1 + LIMIT / 8];
    long received, result;
    if (n > LIMIT || cap > LIMIT) { errno = EINVAL; return -1; }
    request[0] = MAGIC; request[1] = op; request[2] = a; request[3] = b;
    if (n) bytes_copy(request + 4, in, n);
    received = native_call(1, request, 32 + n, reply, 8 + cap);
    if (received < 0) { errno = -received; return -1; }
    if (received < 8) { errno = EIO; return -1; }
    result = (long)reply[0];
    if (result < 0) { errno = -result; return -1; }
    if (received > 8) bytes_copy(out, reply + 1, received - 8);
    return result;
}
static word path_size(const char *path) {
    word n = 0;
    if (!path) { errno = EFAULT; return 0; }
    while (n < LIMIT && path[n]) ++n;
    if (n == LIMIT) { errno = ENAMETOOLONG; return 0; }
    return n + 1;
}
/* Assembly forwards the optional integer argument in the SysV ABI.
   Read it only when required; this also works without TCC's va_arg helper. */
int __native_open(const char *path, int flags, unsigned mode) {
    word n = path_size(path);
    if (!n) return -1;
    return rpc(1, flags, (flags & O_CREAT) ? mode : 0, path, n, 0, 0);
}
int close(int fd) { return rpc(2, fd, 0, 0, 0, 0, 0); }
ssize_t read(int fd, void *data, size_t size) {
    if (size && !data) { errno = EFAULT; return -1; }
    if (size > LIMIT) size = LIMIT;
    return rpc(3, fd, size, 0, 0, data, size);
}
ssize_t write(int fd, const void *data, size_t size) {
    if (size && !data) { errno = EFAULT; return -1; }
    if (size > LIMIT) size = LIMIT;
    return rpc(4, fd, 0, data, size, 0, 0);
}
off_t lseek(int fd, off_t offset, int whence) {
    word w = whence;
    return rpc(5, fd, offset, &w, 8, 0, 0);
}
int dup(int fd) { return rpc(6, fd, 0, 0, 0, 0, 0); }
int dup2(int fd, int to) { return rpc(7, fd, to, 0, 0, 0, 0); }
int __native_fcntl(int fd, int cmd, int value) {
    word arg = (cmd == F_DUPFD || cmd == F_SETFD || cmd == F_SETFL) ? value : 0;
    return rpc(8, fd, cmd, &arg, 8, 0, 0);
}
char *getcwd(char *buf, size_t size) {
    if (!buf || !size) { errno = EINVAL; return 0; }
    if (size > LIMIT) size = LIMIT;
    return rpc(9, size, 0, 0, 0, buf, size) < 0 ? 0 : buf;
}
int chdir(const char *path) {
    word n = path_size(path);
    return n ? rpc(10, 0, 0, path, n, 0, 0) : -1;
}
int poll(struct pollfd *fds, nfds_t count, int timeout) {
    if (count > 256 || (count && !fds)) { errno = EINVAL; return -1; }
    return rpc(11, count, (long)timeout, fds, count * 8, fds, count * 8);
}
pid_t getpid(void) { return rpc(12, 0, 0, 0, 0, 0, 0); }
pid_t getppid(void) { return rpc(13, 0, 0, 0, 0, 0, 0); }
int pipe(int fds[2]) {
    if (!fds) { errno = EFAULT; return -1; }
    return rpc(14, 0, 0, 0, 0, fds, 8);
}

/* TCC can emit this helper for aggregate initialization. */
void *memset(void *data, int value, size_t size) {
    unsigned char *p = data;
    while (size--) *p++ = (unsigned char)value;
    return data;
}

/* Bounded process ABI. Replace this small action pool when malloc is present. */
#include <spawn.h>
#include <sys/wait.h>
#define ACTION_POOLS 8
struct action_buffer { int used; word size, count; unsigned char data[LIMIT]; };
static struct action_buffer action_pool[ACTION_POOLS];
static struct action_buffer *action_buffer(const posix_spawn_file_actions_t *a) {
    int i;
    if (!a) return 0;
    for (i = 0; i < ACTION_POOLS; ++i)
        if (a->actions == &action_pool[i] && action_pool[i].used)
            return &action_pool[i];
    return 0;
}
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *a) {
    int i;
    if (!a) return EINVAL;
    for (i = 0; i < ACTION_POOLS; ++i) if (!action_pool[i].used) {
        action_pool[i].used = 1; action_pool[i].size = action_pool[i].count = 0;
        a->n = 0; a->actions = &action_pool[i]; return 0;
    }
    return ENOMEM;
}
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *a) {
    struct action_buffer *b = action_buffer(a);
    if (!b) return EINVAL;
    b->used = 0; a->actions = 0; a->n = 0; return 0;
}
static int add_action(posix_spawn_file_actions_t *a, word op, word x, word y,
                      word z, const char *path) {
    struct action_buffer *b = action_buffer(a);
    word words[4], n = 0;
    if (!b) return EINVAL;
    if (path) { n = path_size(path); if (!n) return errno; }
    if (b->count == 64 || b->size + 32 + n > LIMIT) return E2BIG;
    words[0] = op; words[1] = x; words[2] = y; words[3] = z;
    bytes_copy(b->data + b->size, words, 32);
    if (n) bytes_copy(b->data + b->size + 32, path, n);
    b->size += 32 + n; ++b->count; a->n = b->count; return 0;
}
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *a, int x, int y) {
    if (x < 0 || x > 4095 || y < 0 || y > 4095) return EBADF;
    return add_action(a, 1, x, y, 0, 0);
}
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *a, int fd) {
    if (fd < 0 || fd > 4095) return EBADF;
    return add_action(a, 2, fd, 0, 0, 0);
}
int posix_spawn_file_actions_addclosefrom_np(posix_spawn_file_actions_t *a, int fd) {
    if (fd < 0 || fd > 4096) return EBADF;
    return add_action(a, 3, fd, 0, 0, 0);
}
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *a, int fd,
                                    const char *path, int flags, mode_t mode) {
    if (fd < 0 || fd > 4095) return EBADF;
    if (!path) return EINVAL;
    return add_action(a, 4, fd, flags, mode, path);
}
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *a,
                                        const char *path) {
    if (!path) return EINVAL;
    return add_action(a, 5, 0, 0, 0, path);
}
int posix_spawnattr_init(posix_spawnattr_t *a) {
    if (!a) return EINVAL;
    memset(a, 0, sizeof(*a)); return 0;
}
int posix_spawnattr_destroy(posix_spawnattr_t *a) { return a ? 0 : EINVAL; }
int posix_spawnattr_setflags(posix_spawnattr_t *a, short flags) {
    if (!a) return EINVAL;
    if (flags) return ENOTSUP;
    a->flags = 0; return 0;
}
int posix_spawnattr_setpgroup(posix_spawnattr_t *a, pid_t p) {
    (void)a; (void)p; return ENOTSUP;
}
int posix_spawnattr_setsigmask(posix_spawnattr_t *a, const sigset_t *s) {
    (void)a; (void)s; return ENOTSUP;
}
int posix_spawnattr_setsigdefault(posix_spawnattr_t *a, const sigset_t *s) {
    (void)a; (void)s; return ENOTSUP;
}
static int pack_string(unsigned char *data, word *at, const char *s) {
    word n = path_size(s);
    if (!n) return errno;
    if (*at + n > LIMIT) return E2BIG;
    bytes_copy(data + *at, s, n); *at += n; return 0;
}
static const char *parent_path(void) {
    char **p = environ;
    if (p) while (*p) {
        const char *s = *p++;
        if (s[0] == 'P' && s[1] == 'A' && s[2] == 'T' && s[3] == 'H' && s[4] == '=')
            return s + 5;
    }
    return "/bin:/usr/bin";
}
static int spawn_process(pid_t *pid, const char *path,
                         const posix_spawn_file_actions_t *actions,
                         const posix_spawnattr_t *attr, char *const argv[],
                         char *const envp[], int search) {
    unsigned char data[LIMIT];
    word counts[3], at = 24, argc = 0, envc = 0, i;
    struct action_buffer *b = action_buffer(actions);
    int e; long result;
    if (!pid || !path || !argv) return EINVAL;
    if (actions && !b) return EINVAL;
    if (attr && attr->flags) return ENOTSUP;
    while (argc < 64 && argv[argc]) ++argc;
    if (argc == 64 && argv[argc]) return E2BIG;
    if (envp) while (envc < 64 && envp[envc]) ++envc;
    if (envc == 64 && envp[envc]) return E2BIG;
    counts[0] = argc; counts[1] = envc; counts[2] = b ? b->count : 0;
    bytes_copy(data, counts, 24);
    if ((e = pack_string(data, &at, path))) return e;
    if ((e = pack_string(data, &at, search ? parent_path() : ""))) return e;
    for (i = 0; i < argc; ++i)
        if ((e = pack_string(data, &at, argv[i]))) return e;
    for (i = 0; i < envc; ++i)
        if ((e = pack_string(data, &at, envp[i]))) return e;
    if (b) {
        if (at + b->size > LIMIT) return E2BIG;
        bytes_copy(data + at, b->data, b->size); at += b->size;
    }
    result = rpc(15, search, 0, data, at, 0, 0);
    if (result < 0) return errno;
    *pid = result; return 0;
}
int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *a, const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[]) {
    return spawn_process(pid, path, a, attr, argv, envp, 0);
}
int posix_spawnp(pid_t *pid, const char *path,
                 const posix_spawn_file_actions_t *a, const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[]) {
    return spawn_process(pid, path, a, attr, argv, envp, 1);
}
pid_t waitpid(pid_t pid, int *status, int options) {
    word code = 0;
    long result = rpc(16, (long)pid, options, 0, 0, &code, 8);
    if (result > 0 && status) *status = code;
    return result;
}
pid_t wait(int *status) { return waitpid(-1, status, 0); }
