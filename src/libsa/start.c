#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "libsa.h"

extern char __tdata_start[], __tdata_end[], __tbss_start[], __tbss_end[], __tls_align[];
extern char **environ;
int main(int argc, char **argv, char **envp);

void *__libsa_tls_new(void *self) {
  uintptr_t align = (uintptr_t)__tls_align;
  if (align < 16) align = 16;
  size_t data = (size_t)(__tdata_end - __tdata_start);
  size_t size = (size_t)(__tbss_end - __tdata_start);
  size = (size + align - 1) & ~(align - 1);
  char *block = aligned_alloc(align, size + 64);
  memset(block, 0, size + 64);
  memcpy(block, __tdata_start, data);
  void **tp = (void **)(block + size);
  tp[0] = tp;
  tp[1] = self;
  return tp;
}

struct main_thread { void *tp; uint64_t tid; void *start, *arg, *retval, *stack; size_t stacksize; };
void *__libsa_main_thread(void);

static void tls_init(void) {
  struct main_thread *m = __libsa_main_thread();
  m->tp = __libsa_tls_new(m);
  m->stack = (void *)(0x00007ff000000000ul - (8ul << 20));
  m->stacksize = 8ul << 20;
  __machdep(MACHDEP_set_cthread_self, (long)m->tp, 0);
  m->tid = (uint64_t)__syscall(SYS_thread_selfid, 0, 0, 0, 0, 0, 0);
}

static char *argv_storage[32];
static char line[1024];

const char *__libsa_run_start(int *argc, char **argv, int max);

void _libsa_start(const char *cmdline) {
  tls_init();
  int argc = 0;
  if (__libsa_run_start(&argc, argv_storage, 32)) exit(main(argc, argv_storage, environ));
  argv_storage[argc++] = "/System/Library/Kernels/kernel";
  const char *rest = strstr(cmdline, "-- ");
  if (rest) {
    strncpy(line, rest + 3, sizeof line - 1);
    for (char *t = strtok(line, " "); t && argc < 31; t = strtok(0, " ")) argv_storage[argc++] = t;
  }
  argv_storage[argc] = 0;
  exit(main(argc, argv_storage, environ));
}
