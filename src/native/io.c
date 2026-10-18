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
