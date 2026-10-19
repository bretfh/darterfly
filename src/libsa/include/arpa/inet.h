#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <netinet/in.h>
const char *inet_ntop(int, const void *, char *, socklen_t);
char *inet_ntoa(struct in_addr);
int inet_aton(const char *, struct in_addr *);
int inet_pton(int, const char *, void *);

#ifdef __cplusplus
}
#endif
