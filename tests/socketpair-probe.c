/* Run by TCC inside Darterfly, through the actual foreign ABI. */
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define CHECK(test) do { if (!(test)) return __LINE__; } while (0)

#include <sys/un.h>
#include <sys/stat.h>
#include <poll.h>
#include <string.h>
#include <stddef.h>
#include <time.h>

static socklen_t local_address(struct sockaddr_un *a, const char *name) {
    memset(a, 0, sizeof(*a));
    a->sun_family = AF_UNIX;
    strcpy(a->sun_path, name);
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(name) + 1);
}

static int named_probe(void) {
    struct sockaddr_un addr, peer;
    struct stat st;
    struct pollfd p[3];
    struct timespec before, after;
    socklen_t size = local_address(&addr, "/tmp/darterfly-nyxt-ipc.sock");
    socklen_t len;
    unsigned char small[8];
    char byte;
    int server, client, accepted, replacement;
    unlink(addr.sun_path);
    server = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    client = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(server >= 3 && client >= 3);
    CHECK(fcntl(server, F_GETFD) == FD_CLOEXEC);
    CHECK(fstat(server, &st) == 0 && S_ISSOCK(st.st_mode));
    CHECK(bind(server, (struct sockaddr *)&addr, 1) == -1 && errno == EINVAL);
    len = sizeof(peer);
    CHECK(getpeername(client, (struct sockaddr *)&peer, &len) == -1 && errno == ENOTCONN);
    CHECK(bind(server, (struct sockaddr *)&addr, size) == 0);
    CHECK(stat(addr.sun_path, &st) == 0 && S_ISSOCK(st.st_mode));
    CHECK(listen(server, 1) == 0);
    CHECK(accept(server, 0, 0) == -1 && errno == EAGAIN);
    p[0].fd = server; p[0].events = POLLIN; p[0].revents = 123;
    CHECK(poll(p, 1, 0) == 0 && p[0].revents == 0);
    CHECK(connect(client, (struct sockaddr *)&addr, size) == 0);
    CHECK(poll(p, 1, 1000) == 1 && p[0].revents == POLLIN);
#ifdef __darterfly__
    /* Darterfly validates this before consuming a queued connection. */
    CHECK(accept(server, (struct sockaddr *)&peer, 0) == -1 && errno == EFAULT);
#endif
    memset(&peer, 0x55, sizeof(peer)); len = sizeof(peer);
    accepted = accept(server, (struct sockaddr *)&peer, &len);
    CHECK(accepted >= 3 && len == 2 && peer.sun_family == AF_UNIX);
    CHECK(fcntl(accepted, F_GETFD) == 0);
    CHECK((fcntl(accepted, F_GETFL) & O_NONBLOCK) == 0);
    len = sizeof(peer);
    CHECK(getpeername(client, (struct sockaddr *)&peer, &len) == 0);
    CHECK(len == size && !strcmp(peer.sun_path, addr.sun_path));
    len = sizeof(peer);
    CHECK(getsockname(accepted, (struct sockaddr *)&peer, &len) == 0);
    CHECK(len == size && !strcmp(peer.sun_path, addr.sun_path));
    memset(small, 0x55, sizeof(small)); len = 3;
    CHECK(getsockname(server, (struct sockaddr *)small, &len) == 0);
    CHECK(len == size && small[0] == AF_UNIX && small[2] == '/');
    CHECK(small[3] == 0x55 && small[7] == 0x55);
    len = 0;
    CHECK(getsockname(server, (struct sockaddr *)small, &len) == 0);
    CHECK(len == size && small[3] == 0x55);
    p[0].fd = accepted; p[0].events = POLLIN;
    p[1].fd = -1; p[1].events = POLLIN; p[1].revents = 99;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &before) == 0);
    CHECK(poll(p, 2, 30) == 0 && p[0].revents == 0 && p[1].revents == 0);
    CHECK(clock_gettime(CLOCK_MONOTONIC, &after) == 0);
    CHECK((after.tv_sec-before.tv_sec)*1000000000L + after.tv_nsec-before.tv_nsec >= 25000000L);
    p[2].fd = 999999; p[2].events = 0;
    CHECK(poll(p, 3, -1) == 1 && p[2].revents == POLLNVAL);
    CHECK(poll(0, 0, 10) == 0);
    CHECK(poll(0, 1, 0) == -1 && errno == EFAULT);
#ifdef __darterfly__
    CHECK(poll(0, 257, 0) == -1 && errno == EINVAL);
#endif
    CHECK(write(client, "x", 1) == 1);
    CHECK(shutdown(client, SHUT_WR) == 0);
    CHECK(poll(p, 2, -1) == 1 && (p[0].revents & POLLIN));
    CHECK(read(accepted, &byte, 1) == 1 && byte == 'x');
    CHECK(read(accepted, &byte, 1) == 0);
    CHECK(write(accepted, "y", 1) == 1);
    CHECK(read(client, &byte, 1) == 1 && byte == 'y');
    CHECK(unlink(addr.sun_path) == 0);
    replacement = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(bind(replacement, (struct sockaddr *)&addr, size) == 0);
    CHECK(listen(replacement, 1) == 0);
    CHECK(close(server) == 0);
    CHECK(close(client) == 0);
    p[0].events = 0;
    CHECK(poll(p, 1, 0) == 1 && (p[0].revents & POLLHUP));
    CHECK(close(accepted) == 0);
    client = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(connect(client, (struct sockaddr *)&addr, size) == 0);
    CHECK(close(replacement) == 0);
    CHECK(read(client, &byte, 1) == 0 || errno == ECONNRESET);
    CHECK(close(client) == 0);
    client = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(connect(client, (struct sockaddr *)&addr, size) == -1 && errno == ECONNREFUSED);
    CHECK(close(client) == 0);
    CHECK(unlink(addr.sun_path) == 0);
    return 0;
}

/* The server is a Lisp thread in the system world; this C client executes
   in a different address space and waits for the delayed response. */
static int world_client(void) {
    struct sockaddr_un addr;
    struct pollfd p;
    char byte;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    socklen_t len = local_address(&addr, "/tmp/nyxt-world.sock");
    CHECK(fd >= 3);
    CHECK(connect(fd, (struct sockaddr *)&addr, len) == 0);
    CHECK(write(fd, "n", 1) == 1);
    p.fd = fd; p.events = POLLIN; p.revents = 0;
    CHECK(poll(&p, 1, 5000) == 1 && (p.revents & POLLIN));
    CHECK(read(fd, &byte, 1) == 1 && byte == 'y');
    CHECK(close(fd) == 0);
    return 0;
}

int main(int argc, char **argv) {
    int status;
    (void)argv;
    if (argc > 1) return world_client();
    status = named_probe();
    if (status) return status;
    int sv[2] = {-1, -1};
    unsigned char byte = 0;
    CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC,
                     0, sv) == 0);
    CHECK(sv[0] >= 3 && sv[1] >= 3 && sv[0] != sv[1]);
    CHECK(fcntl(sv[0], F_GETFD) == FD_CLOEXEC);
    CHECK((fcntl(sv[1], F_GETFL) & O_NONBLOCK) != 0);
    CHECK(read(sv[0], &byte, 1) == -1 && errno == EAGAIN);
    CHECK(write(sv[0], "a", 1) == 1);
    CHECK(write(sv[1], "b", 1) == 1);
    CHECK(read(sv[0], &byte, 1) == 1 && byte == 'b');
    CHECK(read(sv[1], &byte, 1) == 1 && byte == 'a');
    CHECK(write(sv[0], "c", 1) == 1);
    CHECK(shutdown(sv[0], SHUT_WR) == 0);
    CHECK(read(sv[1], &byte, 1) == 1 && byte == 'c');
    CHECK(read(sv[1], &byte, 1) == 0);
    CHECK(write(sv[1], "d", 1) == 1);
    CHECK(read(sv[0], &byte, 1) == 1 && byte == 'd');
    CHECK(close(sv[1]) == 0);
    CHECK(read(sv[0], &byte, 1) == 0);
    CHECK(close(sv[0]) == 0);
    sv[0] = sv[1] = -7;
    CHECK(socketpair(AF_INET, SOCK_STREAM, 0, sv) == -1);
    CHECK(errno == EOPNOTSUPP);
    CHECK(sv[0] == -7 && sv[1] == -7);
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, 0) == -1 && errno == EFAULT);
    return 0;
}
