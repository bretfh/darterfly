#pragma once
#include <stddef.h>
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
void *malloc(size_t);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
void free(void *);
int posix_memalign(void **, size_t, size_t);
void *aligned_alloc(size_t, size_t);
void abort(void) __attribute__((noreturn));
void exit(int) __attribute__((noreturn));
void _Exit(int) __attribute__((noreturn));
int atexit(void (*)(void));
char *getenv(const char *);
int setenv(const char *, const char *, int);
int unsetenv(const char *);
int putenv(char *);
int atoi(const char *);
long atol(const char *);
long strtol(const char *, char **, int);
unsigned long strtoul(const char *, char **, int);
long long strtoll(const char *, char **, int);
unsigned long long strtoull(const char *, char **, int);
double strtod(const char *, char **);
float strtof(const char *, char **);
long double strtold(const char *, char **);
double atof(const char *);
void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
void *bsearch(const void *, const void *, size_t, size_t, int (*)(const void *, const void *));
int abs(int);
long labs(long);
long long llabs(long long);
char *realpath(const char *, char *);
int mkstemp(char *);
int rand(void);
void srand(unsigned);
long random(void);
void srandom(unsigned);
int system(const char *);
