#pragma once
#include <arpa/nameser.h>
#ifdef __cplusplus
extern "C" {
#endif
int res_query(const char *, int, int, unsigned char *, int);
int dn_expand(const unsigned char *, const unsigned char *,
              const unsigned char *, char *, int);
#ifdef __cplusplus
}
#endif
