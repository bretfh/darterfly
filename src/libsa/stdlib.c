#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <sched.h>

#define MIN_CLASS 4
#define MAX_CLASS 19
#define ARENA (1ul << 22)

typedef struct { size_t size; size_t class; } header;

static void *free_lists[MAX_CLASS + 1];
static char malloc_lock;

static void lock(void) {
  while (__atomic_test_and_set(&malloc_lock, __ATOMIC_ACQUIRE)) sched_yield();
}

static void unlock(void) { __atomic_clear(&malloc_lock, __ATOMIC_RELEASE); }
static char *arena_next, *arena_end;

static int class_of(size_t n) {
  int c = MIN_CLASS;
  while ((1ul << c) < n) c++;
  return c;
}

static void *carve(size_t n) {
  if (arena_next + n > arena_end) {
    char *a = mmap(0, ARENA, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (a == MAP_FAILED) return 0;
    arena_next = a;
    arena_end = a + ARENA;
  }
  void *p = arena_next;
  arena_next += n;
  return p;
}

void *malloc(size_t n) {
  size_t total = n + sizeof(header);
  if (total > (1ul << MAX_CLASS)) {
    size_t len = (total + 4095) & ~4095ul;
    header *h = mmap(0, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (h == MAP_FAILED) { errno = ENOMEM; return 0; }
    h->size = n;
    h->class = 0;
    return h + 1;
  }
  int c = class_of(total);
  lock();
  header *h = free_lists[c];
  if (h) free_lists[c] = *(void **)h;
  else h = carve(1ul << c);
  unlock();
  if (!h) { errno = ENOMEM; return 0; }
  h->size = n;
  h->class = (size_t)c;
  return h + 1;
}

void free(void *p) {
  if (!p) return;
  header *h = (header *)p - 1;
  if (!h->class) {
    munmap(h, (h->size + sizeof(header) + 4095) & ~4095ul);
    return;
  }
  lock();
  *(void **)h = free_lists[h->class];
  free_lists[h->class] = h;
  unlock();
}

void *calloc(size_t a, size_t b) {
  size_t n = a * b;
  if (b && n / b != a) { errno = ENOMEM; return 0; }
  void *p = malloc(n);
  if (p) memset(p, 0, n);
  return p;
}

void *realloc(void *p, size_t n) {
  if (!p) return malloc(n);
  header *h = (header *)p - 1;
  if (h->class && n + sizeof(header) <= (1ul << h->class)) {
    h->size = n;
    return p;
  }
  void *q = malloc(n);
  if (!q) return 0;
  memcpy(q, p, h->size < n ? h->size : n);
  free(p);
  return q;
}

int posix_memalign(void **out, size_t align, size_t n) {
  if (align <= 16) {
    *out = malloc(n);
    return *out ? 0 : ENOMEM;
  }
  size_t len = (n + align + 4095) & ~4095ul;
  char *p = mmap(0, len + align, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) return ENOMEM;
  *out = (void *)(((uintptr_t)p + align - 1) & ~(align - 1));
  return 0;
}

void *aligned_alloc(size_t align, size_t n) {
  void *p;
  return posix_memalign(&p, align, n) ? 0 : p;
}

static char *env_storage[64] = {"HOME=/Users/darterfly", "PATH=/bin:/usr/bin", "TERM=dumb", "SBCL_HOME=/usr/lib/sbcl", 0};
char **environ = env_storage;

char *getenv(const char *name) {
  size_t n = strlen(name);
  for (char **e = environ; *e; e++)
    if (!strncmp(*e, name, n) && (*e)[n] == '=') return *e + n + 1;
  return 0;
}

int unsetenv(const char *name) {
  size_t n = strlen(name);
  char **w = environ;
  for (char **e = environ; *e; e++)
    if (strncmp(*e, name, n) || (*e)[n] != '=') *w++ = *e;
  *w = 0;
  return 0;
}

int setenv(const char *name, const char *value, int overwrite) {
  if (getenv(name) && !overwrite) return 0;
  unsetenv(name);
  int i = 0;
  while (environ[i]) i++;
  if (i >= 63) { errno = ENOMEM; return -1; }
  size_t n = strlen(name), v = strlen(value);
  char *s = malloc(n + v + 2);
  memcpy(s, name, n);
  s[n] = '=';
  memcpy(s + n + 1, value, v + 1);
  environ[i] = s;
  environ[i + 1] = 0;
  return 0;
}

int putenv(char *s) {
  char *eq = strchr(s, '=');
  if (!eq) return unsetenv(s);
  char name[256];
  size_t n = (size_t)(eq - s) < sizeof name - 1 ? (size_t)(eq - s) : sizeof name - 1;
  memcpy(name, s, n);
  name[n] = 0;
  return setenv(name, eq + 1, 1);
}

static void (*exit_handlers[32])(void);
static int n_exit_handlers;

int atexit(void (*f)(void)) {
  if (n_exit_handlers == 32) return -1;
  exit_handlers[n_exit_handlers++] = f;
  return 0;
}

void exit(int code) {
  while (n_exit_handlers) exit_handlers[--n_exit_handlers]();
  _exit(code);
}

void _Exit(int code) { _exit(code); }

void abort(void) {
  raise(SIGABRT);
  _exit(134);
}


static unsigned long long seed = 1;
int rand(void) { seed = seed * 6364136223846793005ull + 1; return (int)(seed >> 33); }
void srand(unsigned s) { seed = s; }
long random(void) { return rand(); }
void srandom(unsigned s) { srand(s); }
int system(const char *c) { (void)c; return -1; }

void __assert_fail(const char *e, const char *file, unsigned line, const char *fn) {
  extern int dprintf(int, const char *, ...);
  dprintf(2, "assertion failed: %s at %s:%u in %s\n", e, file, line, fn);
  abort();
}
