#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/socket.h>
#define IFNAMSIZ 16
#define IF_NAMESIZE IFNAMSIZ
struct if_nameindex { unsigned if_index; char *if_name; };
struct ifmap {
    unsigned long mem_start, mem_end;
    unsigned short base_addr;
    unsigned char irq, dma, port;
};
struct ifreq {
    char ifr_name[IFNAMSIZ];
    union {
        struct sockaddr addr, dstaddr, broadaddr, netmask, hwaddr;
        short flags;
        int ivalue, mtu;
        struct ifmap map;
        char slave[IFNAMSIZ], newname[IFNAMSIZ];
        char *data;
    } ifr_ifru;
};
#define ifr_addr ifr_ifru.addr
#define ifr_dstaddr ifr_ifru.dstaddr
#define ifr_broadaddr ifr_ifru.broadaddr
#define ifr_netmask ifr_ifru.netmask
#define ifr_hwaddr ifr_ifru.hwaddr
#define ifr_flags ifr_ifru.flags
#define ifr_ifindex ifr_ifru.ivalue
#define ifr_mtu ifr_ifru.mtu
#define ifr_map ifr_ifru.map
#define ifr_data ifr_ifru.data

#ifdef __cplusplus
}
#endif
