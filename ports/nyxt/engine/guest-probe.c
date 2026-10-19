/* Build in Darterfly, run in a native world, link only shared libsa. */
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/mman.h>

static int check(const char *name, int ok) {
    printf("[ENGINE-BOUNDARY %s %s]\n", name, ok ? "PASS" : "FAIL");
    return ok;
}
int main(void) {
    int ok = 1, pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return 2;
    char value = 0;
    struct pollfd p = {pair[1], POLLIN, 0};
    ok &= check("SOCKET-POLL", write(pair[0], "D", 1) == 1 &&
                poll(&p, 1, 1000) == 1 && (p.revents & POLLIN) &&
                read(pair[1], &value, 1) == 1 && value == 'D');
    close(pair[0]); close(pair[1]);
    int fd = open("/dev/shm/engine-shared", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, 4096)) return 3;
    errno = 0;
    void *map = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int saved = errno;
    if (map != MAP_FAILED) *(char *)map = 'S';
    char shared = 0;
    ok &= check("RAM-SHARED-MAPPING", map != MAP_FAILED &&
                pread(fd, &shared, 1, 0) == 1 && shared == 'S');
    if (map != MAP_FAILED) munmap(map, 4096);
    close(fd); unlink("/dev/shm/engine-shared");
    fd = open("/Users/darterfly/engine-disk-map", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, 4096)) return 4;
    errno = 0;
    map = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    saved = errno;
    ok &= check("DISK-SHARED-UNSUPPORTED", map == MAP_FAILED && saved == EOPNOTSUPP);
    if (map != MAP_FAILED) munmap(map, 4096);
    close(fd); unlink("/Users/darterfly/engine-disk-map");
    void *engine = dlopen("/usr/lib/libcef.so", RTLD_NOW);
    const char *error = dlerror();
    printf("dlopen libcef: %s\n", error ? error : "no error");
    ok &= check("DYNAMIC-LOADING-UNSUPPORTED", !engine && error);
    if (engine) dlclose(engine);
    /* Test the libc shim, not a raw kernel Linux syscall ABI. */
    errno = 0;
    long result = syscall(319, 0L, 0L, 0L, 0L, 0L, 0L);
    saved = errno;
    printf("libsa syscall(319 / Linux memfd_create) errno=%d\n", saved);
    ok &= check("MEMFD-SHIM-UNSUPPORTED", result == -1 && saved == ENOSYS);
    return ok ? 0 : 1;
}
