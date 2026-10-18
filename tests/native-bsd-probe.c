#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>

extern long native_call(unsigned long, const void *, unsigned long,
                        void *, unsigned long);
static int eq(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
#define CHECK(x, n) do { if (!(x)) return n; } while (0)
int main(int argc, char **argv, char **envp) {
    char data[32], cwd[256];
    int fd, copy, pipes[2];
    struct pollfd p;
    CHECK(argc >= 2 && envp == environ, 90);
    if (eq(argv[1], "exit")) return 17;
    if (eq(argv[1], "fault")) *(volatile int *)0x1000 = 1;
    if (eq(argv[1], "loop")) for (;;) __asm__ volatile("pause");
    if (eq(argv[1], "read") || eq(argv[1], "poll")) {
        CHECK(write(2, "ready", 5) == 5, 91);
        if (argv[1][0] == 'p') {
            p.fd = 0; p.events = POLLIN; p.revents = 0;
            return poll(&p, 1, -1) < 0 ? 92 : 0;
        }
        return read(0, data, 1) < 0 ? 93 : 0;
    }
    if (eq(argv[1], "socket")) {
        CHECK(read(0, data, 4) == 4, 94);
        CHECK(write(1, data, 4) == 4, 95);
        return 0;
    }
    if (eq(argv[1], "bad")) {
        unsigned long q[5] = {0x3156534e4644UL, 999, 0, 0, 0};
        long result, denied;
        __asm__ volatile("int $0x82" : "=a"(denied)
                         : "0"(67L), "D"(0L), "S"(0L) : "memory", "cc");
        CHECK(denied == -EPERM, 75);
        CHECK(native_call(1, q, 7, &result, 8) == 8 && result == -22, 70);
        CHECK(native_call(1, q, 32, &result, 8) == 8 && result == -38, 71);
        q[1] = 1; q[4] = ~0UL; /* pathname without a terminator */
        CHECK(native_call(1, q, 40, &result, 8) == 8 && result == -22, 72);
        q[1] = 3; q[3] = ~0UL;
        CHECK(native_call(1, q, 32, &result, 8) == 8 && result == -22, 73);
        q[1] = 7; q[2] = 0; q[3] = ~0UL;
        CHECK(native_call(1, q, 32, &result, 8) == 8 && result == -9, 74);
        return 0;
    }
    CHECK(eq(argv[1], "copy") && argc == 3 && eq(argv[2], "source"), 1);
    CHECK(envp[0] && eq(envp[0], "BUILD=native") && !envp[1], 2);
    CHECK(getcwd(cwd, sizeof cwd) && eq(cwd, "/tmp/native-work"), 3);
    CHECK(getpid() > 0 && getppid() >= 0, 4);
    { int ids[2]; ids[0] = getpid(); ids[1] = getppid();
      CHECK(write(2, ids, sizeof ids) == sizeof ids, 5); }
    CHECK(read(7, data, 2) == 2 && data[0] == 'c' && data[1] == 'd', 6);
    CHECK(write(1, data, 2) == 2, 7);
    CHECK(close(8) == -1 && errno == EBADF, 8);
    CHECK(close(9) == -1 && errno == EBADF, 9);
    CHECK(close(11) == -1 && errno == EBADF, 10);
    CHECK(fcntl(10, F_GETFD) == 0, 11);
    CHECK(close(7) == 0 && dup2(10, 7) == 7, 12);
    CHECK(read(7, data, 2) == 2 && data[0] == 'e' && data[1] == 'f', 13);
    CHECK(close(7) == 0, 14);
    fd = open(argv[2], O_RDONLY);
    CHECK(fd >= 0 && read(fd, data, 4) == 4 && data[0] == 'd', 15);
    CHECK(write(1, data, 4) == 4 && close(fd) == 0, 16);
    fd = open("created", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600U);
    CHECK(fd >= 0 && fcntl(fd, F_GETFD) == FD_CLOEXEC, 17);
    CHECK(write(fd, "built", 5) == 5 && close(fd) == 0, 18);
    CHECK(pipe(pipes) == 0, 19);
    CHECK(write(pipes[1], "p", 1) == 1, 20);
    p.fd = pipes[0]; p.events = POLLIN; p.revents = 0;
    CHECK(poll(&p, 1, 0) == 1 && (p.revents & POLLIN), 21);
    copy = dup(pipes[1]);
    CHECK(copy >= 0 && close(pipes[1]) == 0 && close(copy) == 0, 22);
    CHECK(read(pipes[0], data, 1) == 1 && read(pipes[0], data, 1) == 0, 24);
    CHECK(close(pipes[0]) == 0, 25);
    CHECK(chdir("/") == 0, 26);
    return 23;
}
