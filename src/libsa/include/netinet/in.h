#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/socket.h>
typedef uint32_t in_addr_t;
typedef uint16_t in_port_t;
struct in_addr { in_addr_t s_addr; };
struct in6_addr { union { uint8_t __u6_addr8[16]; uint16_t __u6_addr16[8]; uint32_t __u6_addr32[4]; } __in6_u; };
#define s6_addr __in6_u.__u6_addr8
struct sockaddr_in { sa_family_t sin_family; in_port_t sin_port; struct in_addr sin_addr; unsigned char sin_zero[8]; };
struct sockaddr_in6 { sa_family_t sin6_family; in_port_t sin6_port; uint32_t sin6_flowinfo; struct in6_addr sin6_addr; uint32_t sin6_scope_id; };
#define IPPROTO_IP 0
#define IPPROTO_ICMP 1
#define IPPROTO_IGMP 2
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define IPPROTO_IPV6 41
#define IPPROTO_ICMPV6 58
#define IPPROTO_RAW 255
#define INADDR_LOOPBACK 0x7f000001U
#define INADDR_ANY ((in_addr_t)0x00000000)
#define INET_ADDRSTRLEN 16
#define INET6_ADDRSTRLEN 46

static inline uint16_t htons(uint16_t n) { return __builtin_bswap16(n); }
static inline uint16_t ntohs(uint16_t n) { return __builtin_bswap16(n); }
static inline uint32_t htonl(uint32_t n) { return __builtin_bswap32(n); }
static inline uint32_t ntohl(uint32_t n) { return __builtin_bswap32(n); }
static const struct in6_addr in6addr_any = {{{0}}};
static const struct in6_addr in6addr_loopback = {{{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1}}};
static inline int IN6_IS_ADDR_UNSPECIFIED(const struct in6_addr *a) {
 unsigned i; for (i=0;i<16;i++) if (a->s6_addr[i]) return 0; return 1;
}
static inline int IN6_IS_ADDR_LOOPBACK(const struct in6_addr *a) {
 unsigned i; for (i=0;i<15;i++) if (a->s6_addr[i]) return 0; return a->s6_addr[15]==1;
}
static inline int IN6_IS_ADDR_V4MAPPED(const struct in6_addr *a) {
 unsigned i; for (i=0;i<10;i++) if (a->s6_addr[i]) return 0;
 return a->s6_addr[10]==255 && a->s6_addr[11]==255;
}
#define IN6_IS_ADDR_LINKLOCAL(a) ((a)->s6_addr[0]==0xfe && ((a)->s6_addr[1]&0xc0)==0x80)
#define IN6_IS_ADDR_SITELOCAL(a) ((a)->s6_addr[0]==0xfe && ((a)->s6_addr[1]&0xc0)==0xc0)
#define IN6_IS_ADDR_MULTICAST(a) ((a)->s6_addr[0]==0xff)
#define IN6_IS_ADDR_MC_NODELOCAL(a) (IN6_IS_ADDR_MULTICAST(a) && ((a)->s6_addr[1]&15)==1)
#define IN6_IS_ADDR_MC_LINKLOCAL(a) (IN6_IS_ADDR_MULTICAST(a) && ((a)->s6_addr[1]&15)==2)
#define IN6_IS_ADDR_MC_SITELOCAL(a) (IN6_IS_ADDR_MULTICAST(a) && ((a)->s6_addr[1]&15)==5)
#define IN6_IS_ADDR_MC_ORGLOCAL(a) (IN6_IS_ADDR_MULTICAST(a) && ((a)->s6_addr[1]&15)==8)
#define IN6_IS_ADDR_MC_GLOBAL(a) (IN6_IS_ADDR_MULTICAST(a) && ((a)->s6_addr[1]&15)==14)
#define IN_MULTICAST(a) (((uint32_t)(a)&0xf0000000)==0xe0000000)
#define IP_TTL 2
#define IP_HDRINCL 3
#define IP_MULTICAST_TTL 33
#define IP_MULTICAST_LOOP 34
#define IP_ADD_MEMBERSHIP 35
#define IP_DROP_MEMBERSHIP 36
#define IPV6_UNICAST_HOPS 16
#define IPV6_MULTICAST_IF 17
#define IPV6_MULTICAST_HOPS 18
#define IPV6_MULTICAST_LOOP 19
#define IPV6_JOIN_GROUP 20
#define IPV6_LEAVE_GROUP 21
#define IPV6_V6ONLY 26
struct ip_mreq { struct in_addr imr_multiaddr, imr_interface; };
struct ipv6_mreq { struct in6_addr ipv6mr_multiaddr; unsigned ipv6mr_interface; };

#ifdef __cplusplus
}
#endif
