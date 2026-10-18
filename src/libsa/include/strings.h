#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <string.h>
int strcasecmp(const char *, const char *);
int strncasecmp(const char *, const char *, size_t);
int ffs(int);

#ifdef __cplusplus
}
#endif
