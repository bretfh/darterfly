#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <inttypes.h>

void *memcpy(void *d, const void *s, size_t n) {
  void *r = d;
  __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
  return r;
}

void *memmove(void *d, const void *s, size_t n) {
  unsigned char *p = d;
  const unsigned char *q = s;
  if (p == q || n == 0) return d;
  if (p < q || p >= q + n) {
    void *r = d;
    __asm__ volatile("rep movsb" : "+D"(p), "+S"(q), "+c"(n) : : "memory");
    return r;
  }
  while (n--) p[n] = q[n];
  return d;
}

void *memset(void *d, int c, size_t n) {
  void *r = d;
  __asm__ volatile("rep stosb" : "+D"(d), "+c"(n) : "a"(c) : "memory");
  return r;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *p = a, *q = b;
  for (; n; n--, p++, q++)
    if (*p != *q) return *p - *q;
  return 0;
}

void *memchr(const void *s, int c, size_t n) {
  const unsigned char *p = s;
  for (; n; n--, p++)
    if (*p == (unsigned char)c) return (void *)p;
  return 0;
}

size_t strlen(const char *s) {
  const char *p = s;
  while (*p) p++;
  return (size_t)(p - s);
}

size_t strnlen(const char *s, size_t n) {
  size_t i = 0;
  while (i < n && s[i]) i++;
  return i;
}

char *strcpy(char *d, const char *s) {
  char *r = d;
  while ((*d++ = *s++)) {}
  return r;
}

char *strncpy(char *d, const char *s, size_t n) {
  size_t i = 0;
  for (; i < n && s[i]; i++) d[i] = s[i];
  for (; i < n; i++) d[i] = 0;
  return d;
}

char *strcat(char *d, const char *s) { strcpy(d + strlen(d), s); return d; }

char *strncat(char *d, const char *s, size_t n) {
  char *p = d + strlen(d);
  while (n-- && *s) *p++ = *s++;
  *p = 0;
  return d;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
  for (; n; n--, a++, b++) {
    if (*a != *b) return (unsigned char)*a - (unsigned char)*b;
    if (!*a) return 0;
  }
  return 0;
}

int strcasecmp(const char *a, const char *b) {
  while (*a && tolower(*a) == tolower(*b)) a++, b++;
  return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

int strncasecmp(const char *a, const char *b, size_t n) {
  for (; n; n--, a++, b++) {
    int x = tolower((unsigned char)*a), y = tolower((unsigned char)*b);
    if (x != y) return x - y;
    if (!x) return 0;
  }
  return 0;
}

char *strchr(const char *s, int c) {
  for (;; s++) {
    if (*s == (char)c) return (char *)s;
    if (!*s) return 0;
  }
}

char *strrchr(const char *s, int c) {
  const char *r = 0;
  for (;; s++) {
    if (*s == (char)c) r = s;
    if (!*s) return (char *)r;
  }
}

char *strstr(const char *h, const char *n) {
  size_t k = strlen(n);
  if (!k) return (char *)h;
  for (; *h; h++)
    if (!strncmp(h, n, k)) return (char *)h;
  return 0;
}

size_t strspn(const char *s, const char *a) {
  size_t i = 0;
  while (s[i] && strchr(a, s[i])) i++;
  return i;
}

size_t strcspn(const char *s, const char *r) {
  size_t i = 0;
  while (s[i] && !strchr(r, s[i])) i++;
  return i;
}

char *strpbrk(const char *s, const char *a) {
  s += strcspn(s, a);
  return *s ? (char *)s : 0;
}

char *strtok(char *s, const char *sep) {
  static char *next;
  if (s) next = s;
  if (!next) return 0;
  next += strspn(next, sep);
  if (!*next) return next = 0;
  char *t = next;
  next += strcspn(next, sep);
  if (*next) *next++ = 0;
  else next = 0;
  return t;
}

char *strdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *d = malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

char *strndup(const char *s, size_t n) {
  size_t k = strnlen(s, n);
  char *d = malloc(k + 1);
  if (d) {
    memcpy(d, s, k);
    d[k] = 0;
  }
  return d;
}

int ffs(int i) { return i ? __builtin_ctz((unsigned)i) + 1 : 0; }

static const char *errors[] = {
    [0] = "Success", [EPERM] = "Operation not permitted", [ENOENT] = "No such file or directory",
    [ESRCH] = "No such process", [EINTR] = "Interrupted system call", [EIO] = "Input/output error",
    [EBADF] = "Bad file descriptor", [ECHILD] = "No child processes", [EAGAIN] = "Resource temporarily unavailable",
    [ENOMEM] = "Cannot allocate memory", [EACCES] = "Permission denied", [EFAULT] = "Bad address",
    [EEXIST] = "File exists", [ENOTDIR] = "Not a directory", [EISDIR] = "Is a directory",
    [EINVAL] = "Invalid argument", [EMFILE] = "Too many open files", [ENOTTY] = "Inappropriate ioctl for device",
    [ENOSPC] = "No space left on device", [ESPIPE] = "Illegal seek", [EROFS] = "Read-only file system",
    [EPIPE] = "Broken pipe", [ERANGE] = "Numerical result out of range", [ENOSYS] = "Function not implemented",
    [ENAMETOOLONG] = "File name too long", [ENOTEMPTY] = "Directory not empty", [ELOOP] = "Too many levels of symbolic links",
};

char *strerror(int e) {
  if (e >= 0 && e < (int)(sizeof errors / sizeof *errors) && errors[e]) return (char *)errors[e];
  return "Unknown error";
}

int isdigit(int c) { return c >= '0' && c <= '9'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int isalpha(int c) { return islower(c) || isupper(c); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int isprint(int c) { return c >= 0x20 && c < 0x7f; }
int isgraph(int c) { return c > 0x20 && c < 0x7f; }
int iscntrl(int c) { return (c >= 0 && c < 0x20) || c == 0x7f; }
int ispunct(int c) { return isgraph(c) && !isalnum(c); }
int toupper(int c) { return islower(c) ? c - 32 : c; }
int tolower(int c) { return isupper(c) ? c + 32 : c; }

static unsigned long long parse_unsigned(const char *s, char **end, int base, int *negative, int *overflow) {
  const char *p = s;
  unsigned long long v = 0;
  while (isspace((unsigned char)*p)) p++;
  *negative = 0;
  if (*p == '+' || *p == '-') *negative = *p++ == '-';
  if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') && isxdigit((unsigned char)p[2]))
    p += 2, base = 16;
  else if (base == 0)
    base = *p == '0' ? 8 : 10;
  const char *digits = p;
  *overflow = 0;
  for (;; p++) {
    int d;
    if (isdigit((unsigned char)*p)) d = *p - '0';
    else if (isalpha((unsigned char)*p)) d = tolower((unsigned char)*p) - 'a' + 10;
    else break;
    if (d >= base) break;
    if (v > (~0ull - d) / base) *overflow = 1;
    v = v * base + d;
  }
  if (end) *end = (char *)(p == digits ? s : p);
  return v;
}

unsigned long long strtoull(const char *s, char **end, int base) {
  int neg, over;
  unsigned long long v = parse_unsigned(s, end, base, &neg, &over);
  if (over) { errno = ERANGE; return ~0ull; }
  return neg ? -v : v;
}

unsigned long strtoul(const char *s, char **end, int base) { return strtoull(s, end, base); }

long long strtoll(const char *s, char **end, int base) {
  int neg, over;
  unsigned long long v = parse_unsigned(s, end, base, &neg, &over);
  if (over || v > (neg ? 1ull << 63 : (1ull << 63) - 1)) {
    errno = ERANGE;
    return neg ? LLONG_MIN : LLONG_MAX;
  }
  return neg ? -(long long)v : (long long)v;
}

long strtol(const char *s, char **end, int base) { return strtoll(s, end, base); }
intmax_t strtoimax(const char *s, char **end, int base) { return strtoll(s, end, base); }
uintmax_t strtoumax(const char *s, char **end, int base) { return strtoull(s, end, base); }
int atoi(const char *s) { return (int)strtol(s, 0, 10); }
long atol(const char *s) { return strtol(s, 0, 10); }

double strtod(const char *s, char **end) {
  const char *p = s;
  while (isspace((unsigned char)*p)) p++;
  int neg = 0;
  if (*p == '+' || *p == '-') neg = *p++ == '-';
  double v = 0, scale = 1;
  const char *digits = p;
  while (isdigit((unsigned char)*p)) v = v * 10 + (*p++ - '0');
  if (*p == '.') {
    p++;
    while (isdigit((unsigned char)*p)) v += (*p++ - '0') * (scale /= 10);
  }
  if (p == digits) {
    if (end) *end = (char *)s;
    return 0;
  }
  if (*p == 'e' || *p == 'E') {
    char *e;
    long x = strtol(p + 1, &e, 10);
    if (e != p + 1) {
      p = e;
      while (x > 0) v *= 10, x--;
      while (x < 0) v /= 10, x++;
    }
  }
  if (end) *end = (char *)p;
  return neg ? -v : v;
}

double atof(const char *s) { return strtod(s, 0); }
int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

static void swap(char *a, char *b, size_t n) {
  while (n--) {
    char t = *a;
    *a++ = *b;
    *b++ = t;
  }
}

void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
  char *b = base;
  for (size_t i = 1; i < n; i++)
    for (size_t j = i; j > 0 && cmp(b + (j - 1) * size, b + j * size) > 0; j--) swap(b + (j - 1) * size, b + j * size, size);
}

void *bsearch(const void *key, const void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
  const char *b = base;
  size_t lo = 0, hi = n;
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    int c = cmp(key, b + mid * size);
    if (c == 0) return (void *)(b + mid * size);
    if (c < 0) hi = mid;
    else lo = mid + 1;
  }
  return 0;
}
