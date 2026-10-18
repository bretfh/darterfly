/* Run by TCC inside Darterfly, through the actual foreign ABI. */
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define CHECK(test) do { if (!(test)) return __LINE__; } while (0)

int main(void) {
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
