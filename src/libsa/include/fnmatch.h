#pragma once
#define FNM_PATHNAME 1
#define FNM_NOESCAPE 2
#define FNM_PERIOD 4
#define FNM_LEADING_DIR 8
#define FNM_CASEFOLD 16
#define FNM_NOMATCH 1
#ifdef __cplusplus
extern "C" {
#endif
int fnmatch(const char *, const char *, int);
#ifdef __cplusplus
}
#endif
