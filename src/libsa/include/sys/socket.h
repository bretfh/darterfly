#pragma once
#include <sys/types.h>
typedef unsigned socklen_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_storage { sa_family_t ss_family; char __ss_padding[118]; unsigned long __ss_align; };
struct linger { int l_onoff; int l_linger; };
#define AF_UNSPEC 0
#define AF_LOCAL 1
#define AF_UNIX 1
#define AF_INET 2
#define AF_INET6 10
#define AF_NETLINK 16
#define PF_UNSPEC 0
#define PF_LOCAL 1
#define PF_UNIX 1
#define PF_INET 2
#define PF_INET6 10
#define SOCK_NONBLOCK 00004000
#define SOCK_CLOEXEC 02000000
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_RAW 3
#define SOCK_RDM 4
#define SOCK_SEQPACKET 5
#define SOL_SOCKET 1
#define SO_DEBUG 1
#define SO_REUSEADDR 2
#define SO_TYPE 3
#define SO_ERROR 4
#define SO_DONTROUTE 5
#define SO_BROADCAST 6
#define SO_SNDBUF 7
#define SO_RCVBUF 8
#define SO_KEEPALIVE 9
#define SO_OOBINLINE 10
#define SO_NO_CHECK 11
#define SO_PRIORITY 12
#define SO_LINGER 13
#define SO_BSDCOMPAT 14
#define SO_PASSCRED 16
#define SO_RCVLOWAT 18
#define SO_SNDLOWAT 19
#define SO_RCVTIMEO 20
#define SO_SNDTIMEO 21
#define SO_BINDTODEVICE 25
#define MSG_OOB 1
#define MSG_PEEK 2
#define MSG_DONTROUTE 4
#define MSG_TRUNC 0x20
#define MSG_DONTWAIT 0x40
#define MSG_EOR 0x80
#define MSG_WAITALL 0x100
#define MSG_CONFIRM 0x800
#define MSG_NOSIGNAL 0x4000
#define MSG_MORE 0x8000
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2

int socketpair(int domain, int type, int protocol, int sv[2]);
int shutdown(int fd, int how);
