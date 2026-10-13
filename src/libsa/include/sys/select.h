#pragma once
#include <sys/time.h>
typedef struct { unsigned long fds_bits[16]; } fd_set;
#define FD_SETSIZE 1024
#define FD_ZERO(s) __builtin_memset((s), 0, sizeof *(s))
#define FD_SET(fd, s) ((s)->fds_bits[(fd) / 64] |= 1ul << ((fd) % 64))
#define FD_CLR(fd, s) ((s)->fds_bits[(fd) / 64] &= ~(1ul << ((fd) % 64)))
#define FD_ISSET(fd, s) (((s)->fds_bits[(fd) / 64] >> ((fd) % 64)) & 1)
int select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
