#include <pthread.h>
#include <semaphore.h>
#include <sched.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/mman.h>
#include "libsa.h"

#define UL_COMPARE_AND_WAIT 1
#define ULF_WAKE_ALL 0x100
#define DEFAULT_STACK (8ul << 20)

struct __pthread {
  void *tp;
  uint64_t tid;
  void *(*start)(void *);
  void *arg, *retval;
  void *stack;
  size_t stacksize;
  volatile unsigned done;
  int detached;
  void *specific[PTHREAD_KEYS_MAX];
  char name[32];
};

static int ulock_wait(volatile void *addr, unsigned value, uint64_t usec) {
  long r = __syscall(SYS_ulock_wait, UL_COMPARE_AND_WAIT, (long)addr, value, (long)usec, 0, 0);
  return r < 0 ? errno : 0;
}

static void ulock_wake(volatile void *addr, int all) {
  int saved = errno;
  __syscall(SYS_ulock_wake, UL_COMPARE_AND_WAIT | (all ? ULF_WAKE_ALL : 0), (long)addr, 0, 0, 0, 0);
  errno = saved;
}

static uint64_t usec_until(const struct timespec *abstime) {
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  int64_t usec = (abstime->tv_sec - now.tv_sec) * 1000000 + (abstime->tv_nsec - now.tv_nsec) / 1000;
  return usec <= 0 ? 1 : (uint64_t)usec;
}

static struct __pthread main_thread;

pthread_t __libsa_main_thread(void) { return &main_thread; }

pthread_t pthread_self(void) {
  pthread_t self;
  __asm__("movq %%fs:8, %0" : "=r"(self));
  return self;
}

int pthread_equal(pthread_t a, pthread_t b) { return a == b; }

void *__libsa_tls_new(pthread_t self);

static void _pthread_start(pthread_t self) { pthread_exit(self->start(self->arg)); }

int pthread_create(pthread_t *out, const pthread_attr_t *attr, void *(*start)(void *), void *arg) {
  pthread_t t = calloc(1, sizeof *t);
  if (!t) return EAGAIN;
  t->start = start;
  t->arg = arg;
  t->detached = attr && attr->detach;
  if (attr && attr->stackaddr) {
    t->stack = attr->stackaddr;
    t->stacksize = attr->stacksize;
  } else {
    t->stacksize = attr && attr->stacksize ? attr->stacksize : DEFAULT_STACK;
    t->stack = mmap(0, t->stacksize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (t->stack == MAP_FAILED) { free(t); return EAGAIN; }
  }
  t->tp = __libsa_tls_new(t);
  uint64_t top = (((uint64_t)t->stack + t->stacksize) & ~15ul) - 8;
  long tid = __syscall(SYS_bsdthread_create, (long)_pthread_start, (long)t, (long)top, (long)t->tp, 0, 0);
  if (tid < 0) { free(t); return EAGAIN; }
  t->tid = (uint64_t)tid;
  *out = t;
  return 0;
}

void pthread_exit(void *value) {
  pthread_t self = pthread_self();
  self->retval = value;
  self->done = 1;
  ulock_wake(&self->done, 1);
  __syscall(SYS_bsdthread_terminate, 0, 0, 0, 0, 0, 0);
  for (;;) {}
}

int pthread_join(pthread_t t, void **value) {
  while (!t->done) ulock_wait(&t->done, 0, 0);
  if (value) *value = t->retval;
  return 0;
}

int pthread_detach(pthread_t t) { t->detached = 1; return 0; }

int pthread_kill(pthread_t t, int sig) {
  long r = __syscall(SYS___pthread_kill, (long)t->tid, sig, 0, 0, 0, 0);
  return r < 0 ? errno : 0;
}

int pthread_attr_init(pthread_attr_t *a) { memset(a, 0, sizeof *a); return 0; }
int pthread_attr_destroy(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_setstack(pthread_attr_t *a, void *s, size_t n) { a->stackaddr = s; a->stacksize = n; return 0; }
int pthread_attr_getstack(const pthread_attr_t *a, void **s, size_t *n) { *s = a->stackaddr; *n = a->stacksize; return 0; }
int pthread_attr_setstacksize(pthread_attr_t *a, size_t n) { a->stacksize = n; return 0; }
int pthread_attr_getstacksize(const pthread_attr_t *a, size_t *n) { *n = a->stacksize ? a->stacksize : DEFAULT_STACK; return 0; }
int pthread_attr_setguardsize(pthread_attr_t *a, size_t n) { a->guardsize = n; return 0; }
int pthread_attr_getguardsize(const pthread_attr_t *a, size_t *n) { *n = a->guardsize; return 0; }
int pthread_attr_setdetachstate(pthread_attr_t *a, int d) { a->detach = d; return 0; }

int pthread_getattr_np(pthread_t t, pthread_attr_t *a) {
  memset(a, 0, sizeof *a);
  a->stackaddr = t->stack;
  a->stacksize = t->stacksize;
  return 0;
}

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) {
  memset((void *)m, 0, sizeof *m);
  m->kind = a ? a->kind : 0;
  return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }

static int self_id(void) { return (int)pthread_self()->tid; }

int pthread_mutex_trylock(pthread_mutex_t *m) {
  if (m->kind == PTHREAD_MUTEX_RECURSIVE && m->owner == self_id()) { m->count++; return 0; }
  int expected = 0;
  if (!__atomic_compare_exchange_n(&m->state, &expected, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return EBUSY;
  m->owner = self_id();
  m->count = 1;
  return 0;
}

static int lock_until(pthread_mutex_t *m, uint64_t usec) {
  if (m->kind == PTHREAD_MUTEX_RECURSIVE && m->owner == self_id()) { m->count++; return 0; }
  int c = 0;
  if (!__atomic_compare_exchange_n(&m->state, &c, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
    if (c != 2) c = __atomic_exchange_n(&m->state, 2, __ATOMIC_ACQUIRE);
    while (c != 0) {
      if (ulock_wait(&m->state, 2, usec) == ETIMEDOUT) return ETIMEDOUT;
      c = __atomic_exchange_n(&m->state, 2, __ATOMIC_ACQUIRE);
    }
  }
  m->owner = self_id();
  m->count = 1;
  return 0;
}

int pthread_mutex_lock(pthread_mutex_t *m) { return lock_until(m, 0); }
int pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *t) { return lock_until(m, usec_until(t)); }

int pthread_mutex_unlock(pthread_mutex_t *m) {
  if (m->kind == PTHREAD_MUTEX_RECURSIVE && --m->count > 0) return 0;
  m->owner = 0;
  if (__atomic_fetch_sub(&m->state, 1, __ATOMIC_RELEASE) != 1) {
    __atomic_store_n(&m->state, 0, __ATOMIC_RELEASE);
    ulock_wake(&m->state, 0);
  }
  return 0;
}

int pthread_mutexattr_init(pthread_mutexattr_t *a) { a->kind = 0; return 0; }
int pthread_mutexattr_destroy(pthread_mutexattr_t *a) { (void)a; return 0; }
int pthread_mutexattr_settype(pthread_mutexattr_t *a, int k) { a->kind = k; return 0; }

int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) { (void)a; c->seq = 0; return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }

static int cond_wait(pthread_cond_t *c, pthread_mutex_t *m, uint64_t usec) {
  unsigned seq = c->seq;
  int count = m->count;
  m->count = 1;
  pthread_mutex_unlock(m);
  int r = ulock_wait(&c->seq, seq, usec);
  pthread_mutex_lock(m);
  m->count = count;
  return r == ETIMEDOUT ? ETIMEDOUT : 0;
}

int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { return cond_wait(c, m, 0); }
int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *t) { return cond_wait(c, m, usec_until(t)); }
int pthread_cond_signal(pthread_cond_t *c) { __atomic_fetch_add(&c->seq, 1, __ATOMIC_RELEASE); ulock_wake(&c->seq, 0); return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { __atomic_fetch_add(&c->seq, 1, __ATOMIC_RELEASE); ulock_wake(&c->seq, 1); return 0; }
int pthread_condattr_init(pthread_condattr_t *a) { memset(a, 0, sizeof *a); return 0; }
int pthread_condattr_destroy(pthread_condattr_t *a) { (void)a; return 0; }
int pthread_condattr_setpshared(pthread_condattr_t *a, int p) { a->pshared = p; return 0; }
int pthread_condattr_setclock(pthread_condattr_t *a, clockid_t c) { a->clock = c; return 0; }

static volatile unsigned next_key;
static void (*destructors[PTHREAD_KEYS_MAX])(void *);

int pthread_key_create(pthread_key_t *k, void (*d)(void *)) {
  unsigned key = __atomic_fetch_add(&next_key, 1, __ATOMIC_RELAXED);
  if (key >= PTHREAD_KEYS_MAX) return EAGAIN;
  destructors[key] = d;
  *k = key;
  return 0;
}

int pthread_key_delete(pthread_key_t k) { (void)k; return 0; }
void *pthread_getspecific(pthread_key_t k) { return pthread_self()->specific[k]; }
int pthread_setspecific(pthread_key_t k, const void *v) { pthread_self()->specific[k] = (void *)v; return 0; }

int pthread_once(pthread_once_t *o, void (*f)(void)) {
  int expected = 0;
  if (__atomic_compare_exchange_n(o, &expected, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
    f();
    __atomic_store_n(o, 2, __ATOMIC_RELEASE);
    ulock_wake(o, 1);
  } else
    while (*o != 2) ulock_wait(o, 1, 0);
  return 0;
}

int pthread_setname_np(pthread_t t, const char *n) { strncpy(t->name, n, sizeof t->name - 1); return 0; }
int pthread_getname_np(pthread_t t, char *n, size_t len) { strncpy(n, t->name, len); return 0; }

int sched_yield(void) {
  long n = -60;
  __asm__ volatile("int $0x81" : "+a"(n) : : "memory", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "cc");
  return 0;
}

int sem_init(sem_t *s, int pshared, unsigned v) { (void)pshared; s->count = v; return 0; }
int sem_destroy(sem_t *s) { (void)s; return 0; }

int sem_trywait(sem_t *s) {
  unsigned v = s->count;
  while (v > 0)
    if (__atomic_compare_exchange_n(&s->count, &v, v - 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return 0;
  errno = EAGAIN;
  return -1;
}

static int sem_wait_until(sem_t *s, uint64_t usec) {
  for (;;) {
    if (sem_trywait(s) == 0) return 0;
    int r = ulock_wait(&s->count, 0, usec);
    if (r == ETIMEDOUT || r == EINTR) { errno = r; return -1; }
  }
}

int sem_wait(sem_t *s) { return sem_wait_until(s, 0); }
int sem_timedwait(sem_t *s, const struct timespec *t) { return sem_wait_until(s, usec_until(t)); }
int sem_post(sem_t *s) { __atomic_fetch_add(&s->count, 1, __ATOMIC_RELEASE); ulock_wake(&s->count, 0); return 0; }
int sem_getvalue(sem_t *s, int *v) { *v = (int)s->count; return 0; }
