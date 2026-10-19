#pragma once
#include <stdint.h>
#define C_IN 1
#define T_A 1
#define T_NS 2
#define T_CNAME 5
#define T_SOA 6
#define T_PTR 12
#define T_MX 15
#define T_TXT 16
#define T_AAAA 28
#define T_SRV 33
#define NS_PACKETSZ 512
#define NS_MAXDNAME 1025
#define NS_HFIXEDSZ 12
/* Darterfly's supported x86-64 ABI is little endian. */
typedef struct {
 uint16_t id;
 unsigned char rd:1, tc:1, aa:1, opcode:4, qr:1;
 unsigned char rcode:4, cd:1, ad:1, unused:1, ra:1;
 uint16_t qdcount, ancount, nscount, arcount;
} HEADER;
#define GETSHORT(s, p) do { (s) = ((uint16_t)(p)[0]<<8) | (p)[1]; (p) += 2; } while (0)
#define GETLONG(l, p) do { (l) = ((uint32_t)(p)[0]<<24) | ((uint32_t)(p)[1]<<16) | ((uint32_t)(p)[2]<<8) | (p)[3]; (p) += 4; } while (0)
