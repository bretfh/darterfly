#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
#include <pthread.h>
#include <sys/mman.h>

extern long native_call(unsigned long, const void *, unsigned long,
                        void *, unsigned long);
static int eq(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
#define CHECK(x, n) do { if (!(x)) return n; } while (0)
/* A buffered FILE must keep one logical position across every read API.
   Exercise real shared-libsa streams in an isolated native world. */
static int stdio_check(void) {
    FILE *f;
    char b[80], userbuf[7], block[8192];
    int pipes[2], i, lines = 0;
    f = fopen("/tmp/stdio-buffer", "w+");
    CHECK(f && fwrite("one\ntwo\nlast", 1, 12, f) == 12, 180);
    CHECK(fseek(f, 0, SEEK_SET) == 0, 181);
    CHECK(fgets(b, sizeof b, f) == b && eq(b, "one\n"), 182);
    CHECK(ftell(f) == 4 && fgetc(f) == 't', 183);
    CHECK(ungetc('T', f) == 'T' && ftello(f) == 4, 184);
    CHECK(fread(b, 2, 2, f) == 2 && b[0] == 'T' && b[3] == '\n', 185);
    CHECK(fseeko(f, -4, SEEK_CUR) == 0 && fgetc(f) == 't', 186);
    CHECK(fflush(f) == 0 && lseek(fileno(f), 0, SEEK_CUR) == 5, 187);
    CHECK(fgets(b, 2, f) == b && eq(b, "w") && ftell(f) == 6, 188);
    CHECK(fseek(f, 0, SEEK_CUR) == 0 && fputc('X', f) == 'X', 189);
    CHECK(fseek(f, 4, SEEK_SET) == 0 && fgets(b, sizeof b, f) && eq(b, "twX\n"), 190);
    CHECK(fread(b, 3, 2, f) == 1 && b[0] == 'l' && b[3] == 't' && feof(f), 191);
    CHECK(ungetc('!', f) == '!' && !feof(f) && fgetc(f) == '!', 192);
    CHECK(fgetc(f) == EOF && feof(f), 193);
    rewind(f);
    CHECK(!feof(f) && !ferror(f) && ftell(f) == 0, 194);
    CHECK(setvbuf(f, userbuf, _IOFBF, sizeof userbuf) == 0, 195);
    CHECK(fgets(b, sizeof b, f) && eq(b, "one\n"), 196);
    CHECK(fgets(b, sizeof b, f) && eq(b, "twX\n"), 197);
    CHECK(freopen("/tmp/shared-runtime", "r", f) == f, 198);
    CHECK(fread(b, 1, 5, f) == 5 && b[0] == 'l' && b[4] == 'a', 199);
    CHECK(fclose(f) == 0, 200); /* userbuf must never be freed. */
    CHECK(pipe(pipes) == 0 && write(pipes[1], "ab\ncd", 5) == 5, 201);
    close(pipes[1]);
    f = fdopen(pipes[0], "r");
    CHECK(f && fgets(b, sizeof b, f) && eq(b, "ab\n"), 202);
    CHECK(fseek(f, 0, SEEK_SET) == -1 && fgetc(f) == 'c', 203);
    CHECK(fread(b, 1, 2, f) == 1 && b[0] == 'd' && feof(f), 204);
    CHECK(fclose(f) == 0, 205);
    f = fopen("/tmp/shared-runtime", "r");
    CHECK(f && setvbuf(f, 0, _IONBF, 0) == 0 && fgetc(f) == 'l', 206);
    CHECK(lseek(fileno(f), 0, SEEK_CUR) == 1, 207);
    CHECK(fread(b, 0, (size_t)-1, f) == 0 && !feof(f) && !ferror(f), 208);
    CHECK(fgets(b, 1, f) == b && b[0] == 0 && ftell(f) == 1, 209);
    CHECK(fclose(f) == 0, 210);
    f = fopen("/tmp/stdio-lines", "w");
    CHECK(f, 211);
    for (i = 0; i < sizeof block; ++i) block[i] = i % 64 == 63 ? '\n' : 'x';
    for (i = 0; i < 32; ++i) CHECK(fwrite(block, 1, sizeof block, f) == sizeof block, 212);
    CHECK(fclose(f) == 0, 213);
    f = fopen("/tmp/stdio-lines", "r");
    CHECK(f, 214);
    while (fgets(b, sizeof b, f)) {
        CHECK(b[0] == 'x' && b[62] == 'x' && b[63] == '\n' && b[64] == 0, 215);
        ++lines;
    }
    CHECK(lines == 4096 && feof(f) && !ferror(f) && ftell(f) == 262144, 216);
    CHECK(fclose(f) == 0, 217);
    return 0;
}

static int runtime_check(void) {
    size_t i;
    unsigned char *p = calloc(4096, 1);
    FILE *f;
    struct stat st;
    char text[8];
    CHECK(p, 160);
    CHECK(malloc((size_t)-1) == 0 && errno == ENOMEM, 176);
    CHECK(calloc((size_t)-1, 2) == 0 && errno == ENOMEM, 177);
    for (i = 0; i < 4096; ++i) CHECK(p[i] == 0, 161);
    p[4095] = 42;
    p = realloc(p, 1048576);
    CHECK(p && p[4095] == 42, 162);
    p[1048575] = 19;
    CHECK(p[1048575] == 19, 163);
    free(p);
    p = aligned_alloc(64, 128);
    CHECK(p && ((unsigned long)p % 64) == 0, 164);
    p[127] = 71;
    p = realloc(p, 256);
    CHECK(p && p[127] == 71, 172);
    free(p);
    { void *untouched = (void *)1;
      CHECK(posix_memalign(&untouched, 24, 128) == EINVAL &&
            untouched == (void *)1, 173); }
    { posix_spawn_file_actions_t actions[16];
      for (i = 0; i < 16; ++i)
          CHECK(posix_spawn_file_actions_init(&actions[i]) == 0, 174);
      for (i = 0; i < 16; ++i)
          CHECK(posix_spawn_file_actions_destroy(&actions[i]) == 0, 175); }
    CHECK(setenv("ADDED", "working", 1) == 0, 165);
    CHECK(eq(getenv("ADDED"), "working"), 166);
    CHECK(unsetenv("ADDED") == 0 && !getenv("ADDED"), 167);
    f = fopen("/tmp/shared-runtime", "w");
    CHECK(f && fwrite("libsa", 1, 5, f) == 5 && fclose(f) == 0, 168);
    f = fopen("/tmp/shared-runtime", "r");
    CHECK(f && fread(text, 1, 5, f) == 5 && fclose(f) == 0, 169);
    text[5] = 0;
    CHECK(eq(text, "libsa"), 170);
    CHECK(stat("/tmp/shared-runtime", &st) == 0 && st.st_size == 5, 171);
    return stdio_check();
}

static int child_driver(char *path) {
    posix_spawn_file_actions_t a;
    posix_spawnattr_t attr;
    pid_t child = -123;
    int input[2], output[2], diag[2], status, ids[2], i;
    char data[4];
    char *args[] = {path, "child-check", "space in argument", 0};
    char *env[] = {"CHILD=exact value", 0};
    CHECK(pipe(input) == 0 && pipe(output) == 0 && pipe(diag) == 0, 101);
    CHECK(posix_spawn_file_actions_init(&a) == 0, 102);
    CHECK(posix_spawn_file_actions_adddup2(&a, input[0], 0) == 0, 103);
    CHECK(posix_spawn_file_actions_adddup2(&a, output[1], 1) == 0, 104);
    CHECK(posix_spawn_file_actions_adddup2(&a, diag[1], 2) == 0, 105);
    CHECK(posix_spawn_file_actions_addclosefrom_np(&a, 3) == 0, 106);
    CHECK(posix_spawn_file_actions_addchdir_np(&a, "/tmp/native-work") == 0, 107);
    CHECK(posix_spawn(&child, path, &a, 0, args, env) == 0, 108);
    CHECK(posix_spawn_file_actions_destroy(&a) == 0, 109);
    close(input[0]); close(output[1]); close(diag[1]);
    status = 0x12345678;
    CHECK(waitpid(child, &status, WNOHANG) == 0 && status == 0x12345678, 110);
    CHECK(write(input[1], "link", 4) == 4 && close(input[1]) == 0, 111);
    CHECK(read(output[0], data, 4) == 4 && data[0] == 'l' && data[3] == 'k', 112);
    CHECK(read(diag[0], ids, sizeof ids) == sizeof ids, 113);
    CHECK(ids[0] == child && ids[1] == getpid(), 114);
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status)
          && WEXITSTATUS(status) == 29, 115);
    CHECK(read(output[0], data, 4) == 0, 116);
    close(output[0]); close(diag[0]);
    CHECK(waitpid(child, &status, 0) == -1 && errno == ECHILD, 117);
    CHECK(waitpid(getpid(), &status, 0) == -1 && errno == ECHILD, 118);
    CHECK(posix_spawn_file_actions_init(&a) == 0, 141);
    CHECK(posix_spawn_file_actions_addchdir_np(&a, "/tmp/native-work") == 0, 142);
    CHECK(posix_spawn_file_actions_addopen(&a, 0, "source", O_RDONLY, 0) == 0, 143);
    CHECK(posix_spawn_file_actions_addopen(&a, 1, "child-artifact",
                                          O_WRONLY | O_CREAT | O_TRUNC, 0600) == 0, 144);
    CHECK(posix_spawn_file_actions_addopen(&a, 8, "source", O_RDONLY, 0) == 0, 145);
    CHECK(posix_spawn_file_actions_addclose(&a, 8) == 0, 146);
    args[1] = "socket";
    CHECK(posix_spawn(&child, path, &a, 0, args, env) == 0, 147);
    CHECK(posix_spawn_file_actions_destroy(&a) == 0, 148);
    CHECK(waitpid(child, &status, 0) == child && status == 0, 149);
    i = open("/tmp/native-work/child-artifact", O_RDONLY);
    CHECK(i >= 0 && read(i, data, 4) == 4 && data[0] == 'd' && data[3] == 'a', 150);
    close(i);
    args[1] = "fault";
    CHECK(posix_spawn(&child, path, 0, 0, args, env) == 0, 119);
    CHECK(waitpid(-1, &status, 0) == child && WTERMSIG(status) == 11, 120);
    CHECK(posix_spawn(&child, "/tmp/native-registered", 0, 0, args, env)
          == ENOEXEC, 151);
    child = -123;
    CHECK(posix_spawn(&child, "/does-not-exist", 0, 0, args, env) == ENOENT
          && child == -123, 121);
    CHECK(posix_spawn_file_actions_init(&a) == 0, 122);
    CHECK(posix_spawn_file_actions_adddup2(&a, 4095, 1) == 0, 123);
    CHECK(posix_spawn(&child, path, &a, 0, args, env) == EBADF, 124);
    CHECK(posix_spawn_file_actions_destroy(&a) == 0, 125);
    CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD, 126);
    CHECK(posix_spawnattr_init(&attr) == 0, 127);
    CHECK(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP) == ENOTSUP, 128);
    args[1] = "exit";
    for (i = 0; i < 16; ++i) {
        CHECK(posix_spawn(&child, path, 0, &attr, args, env) == 0, 129);
        CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 17, 130);
    }
    /* PATH comes from the parent, not the replacement child's environment. */
    { char *old_path = environ[0];
      environ[0] = "PATH=/absent:/Users/darterfly";
      CHECK(posix_spawnp(&child, "native-bsd-probe", 0, 0, args, env) == 0, 131);
      environ[0] = old_path;
      CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 17, 132); }
    return 0;
}

/* Repeated protection changes must not consume permanent map entries.
   A genuinely full map must fail atomically instead of panicking the OS. */
static int map_churn(void) {
    const size_t size = 4096 * 4096;
    unsigned char *p = mmap(0, size, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    void *maps[2048];
    int count = 0, i;
    CHECK(p != MAP_FAILED, 225);
    for (i = 0; i < 4096; ++i) {
        p[i * 4096] = 73;
        CHECK(!mprotect(p + i * 4096, 4096, PROT_READ), 226);
        CHECK(p[i * 4096] == 73, 227);
        CHECK(!mprotect(p + i * 4096, 4096, PROT_READ | PROT_WRITE), 228);
    }
    while (count < 2048) {
        void *m = mmap(0, 4096, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (m == MAP_FAILED) break;
        maps[count++] = m;
    }
    CHECK(count > 0 && count < 2048 && errno == ENOMEM, 229);
    CHECK(mprotect(p + 4096, 4096, PROT_READ) == -1 && errno == ENOMEM, 230);
    p[4096] = 91; /* Failed protection must leave the old mapping writable. */
    CHECK(p[4096] == 91, 231);
    for (i = 0; i < count; ++i) CHECK(!munmap(maps[i], 4096), 232);
    CHECK(!munmap(p, size), 233);
    p = mmap(0, 4096, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(p != MAP_FAILED && !munmap(p, 4096), 234);
    return 0;
}

/* Stop must also reap threads returning from a scheduler park, and syscalls
   already queued at the kernel funnel. Exercise waits and thread creation. */
static void *sleeping_worker(void *unused) {
    (void)unused;
    for (;;) usleep(1000);
    return 0;
}
static void *short_worker(void *unused) { return unused; }
static int thread_reuse(void) {
    pthread_t th;
    void *result, *stack;
    pthread_attr_t attr;
    int i;
    /* More creations than the VM map capacity; each owned stack must leave. */
    for (i = 0; i < 2048; ++i) {
        CHECK(!pthread_create(&th, 0, short_worker, (void *)37), 235);
        CHECK(!pthread_join(th, &result) && result == (void *)37, 236);
    }
    stack = mmap(0, 65536, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(stack != MAP_FAILED && !pthread_attr_init(&attr), 237);
    CHECK(!pthread_attr_setstack(&attr, stack, 65536), 238);
    for (i = 0; i < 32; ++i) {
        CHECK(!pthread_create(&th, &attr, short_worker, (void *)41), 239);
        CHECK(!pthread_join(th, &result) && result == (void *)41, 240);
        *(volatile unsigned char *)stack = 93; /* Borrowed, still ours. */
    }
    CHECK(!pthread_attr_destroy(&attr) && !munmap(stack, 65536), 241);
    return 0;
}

static int stop_threads(int churn) {
    pthread_t a, b;
    CHECK(!pthread_create(&a, 0, sleeping_worker, 0), 220);
    CHECK(!pthread_create(&b, 0, sleeping_worker, 0), 221);
    CHECK(write(2, "ready", 5) == 5, 222);
    if (!churn) return pthread_join(a, 0);
    for (;;) {
        pthread_t child;
        CHECK(!pthread_create(&child, 0, short_worker, 0), 223);
        CHECK(!pthread_join(child, 0), 224);
    }
}

int main(int argc, char **argv, char **envp) {
    char data[32], cwd[256];
    int fd, copy, pipes[2];
    struct pollfd p;
    CHECK(argc >= 2 && envp == environ, 90);
    if (eq(argv[1], "stop-threads")) return stop_threads(0);
    if (eq(argv[1], "churn-threads")) return stop_threads(1);
    if (eq(argv[1], "thread-reuse")) return thread_reuse();
    if (eq(argv[1], "map-churn")) return map_churn();
    if (eq(argv[1], "runtime")) return runtime_check();
    if (eq(argv[1], "children")) return child_driver(argv[0]);
    if (eq(argv[1], "child-check")) {
        int ids[2];
        CHECK(argc == 3 && eq(argv[2], "space in argument"), 133);
        CHECK(envp[0] && eq(envp[0], "CHILD=exact value") && !envp[1], 134);
        CHECK(getcwd(cwd, sizeof cwd) && eq(cwd, "/tmp/native-work"), 135);
        ids[0] = getpid(); ids[1] = getppid();
        CHECK(write(2, ids, sizeof ids) == sizeof ids, 136);
        CHECK(read(0, data, 4) == 4 && write(1, data, 4) == 4, 137);
        return 29;
    }
    if (eq(argv[1], "wait-child")) {
        char *args[] = {argv[0], "loop", 0};
        pid_t child; int status;
        CHECK(posix_spawn(&child, argv[0], 0, 0, args, envp) == 0, 138);
        CHECK(write(2, &child, sizeof child) == sizeof child, 139);
        return waitpid(child, &status, 0) == child ? 0 : 140;
    }
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
        unsigned long q[10] = {1, 999, 0, 0, 0, 0, 0, 0, 0, 0};
        long reply[3], denied;
        /* Hardware and supervisor-native calls require explicit rights. */
        const long restricted[] = {65, 66, 67, 68, 80, 81, 82, 83, 85, 87};
        for (unsigned i = 0; i < sizeof restricted / sizeof restricted[0]; ++i) {
            __asm__ volatile("int $0x82; jnc 1f; neg %%rax; 1:"
                             : "=a"(denied)
                             : "0"(restricted[i]), "D"(0L), "S"(0L)
                             : "memory", "cc");
            CHECK(denied == -EPERM, 75);
        }
        CHECK(native_call(1, q, 7, reply, 24) == 24 && reply[0] == -22, 70);
        CHECK(native_call(1, q, 72, reply, 24) == 24 && reply[0] == -38, 71);
        q[1] = 1; q[2] = 0x1000; /* forged supervisor pathname pointer */
        CHECK(native_call(1, q, 72, reply, 24) == 24 && reply[0] == -22, 72);
        q[1] = 37; /* forged status pointer */
        CHECK(native_call(1, q, 72, reply, 24) == 24 && reply[0] == -22, 73);
        q[1] = 28; q[2] = 0; q[3] = ~0UL;
        CHECK(native_call(1, q, 72, reply, 24) == 24 && reply[0] == -22, 74);
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
