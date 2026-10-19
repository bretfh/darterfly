#pragma once
#ifdef __cplusplus
extern "C" {
#endif
extern int h_errno;
struct hostent { char *h_name; char **h_aliases; int h_addrtype, h_length; char **h_addr_list; };
struct hostent *gethostbyname(const char *);
struct hostent *gethostbyaddr(const void *, unsigned, int);
#include <netinet/in.h>
struct protoent { char *p_name; char **p_aliases; int p_proto; };
struct addrinfo { int ai_flags; int ai_family; int ai_socktype; int ai_protocol; socklen_t ai_addrlen; struct sockaddr *ai_addr; char *ai_canonname; struct addrinfo *ai_next; };
#define EAI_BADFLAGS -1
#define EAI_NONAME -2
#define EAI_AGAIN -3
#define EAI_FAIL -4
#define EAI_FAMILY -6
#define EAI_SOCKTYPE -7
#define EAI_SERVICE -8
#define EAI_ADDRFAMILY -9
#define EAI_MEMORY -10
#define EAI_SYSTEM -11
#define NI_NAMEREQD 8

#ifdef __cplusplus
}
#endif
