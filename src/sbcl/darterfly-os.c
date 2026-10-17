#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include "os.h"
#include "interr.h"
#include "interrupt.h"
#include "arch.h"
#include "gc.h"
#include "validate.h"
#include "thread.h"

long __syscall(long n, long a, long b, long c, long d, long e, long f);

int sb_GetTID() { return (int)__syscall(372, 0, 0, 0, 0, 0, 0); }

void os_init() {}

int os_preinit(char *argv[], char *envp[]) {
  (void)argv;
  (void)envp;
  return allocate_hardwired_spaces(0);
}

os_vm_address_t os_alloc_gc_space(int space_id, int attributes, os_vm_address_t addr, os_vm_size_t len) {
  (void)space_id;
  int protection = attributes & IS_GUARD_PAGE ? OS_VM_PROT_NONE : OS_VM_PROT_ALL;
  int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | (addr ? MAP_FIXED : 0);
  os_vm_address_t actual = mmap(addr, len, protection, flags, -1, 0);
  if (actual == MAP_FAILED) {
    perror("mmap");
    return 0;
  }
  return actual;
}

char *os_get_runtime_executable_path() { return strdup("/System/Library/Kernels/kernel"); }

static void sigsegv_handler(int signal, siginfo_t *info, os_context_t *context) {
  os_vm_address_t addr = arch_get_bad_addr(signal, info, context);
#ifdef LISP_FEATURE_SB_SAFEPOINT
  if (handle_safepoint_violation(context, addr)) return;
#endif
  if (gencgc_handle_wp_violation(context, addr)) return;
#ifdef LISP_FEATURE_TLS_LOAD_INDIRECT
  if (handle_tls_deref_trap(context, addr)) return;
#endif
  if (!handle_guard_page_triggered(context, addr)) lisp_memory_fault_error(context, addr);
}

void os_install_interrupt_handlers(void) {
  if (INSTALL_SIG_MEMORY_FAULT_HANDLER) ll_install_handler(SIG_MEMORY_FAULT, sigsegv_handler);
}

#ifdef LISP_FEATURE_SB_FUTEX
#include "genesis/vector.h"

bool futex_private_supported_p = 1;

char *futex_name(int *lock_word) {
  lispobj name = ((lispobj *)lock_word)[1];
  if (lowtag_of(name) == OTHER_POINTER_LOWTAG && simple_base_string_p(name)) return vector_sap(name);
  return 0;
}

int futex_wait(int *lock_word, int oldval, long sec, unsigned long usec) {
  long timeout = sec < 0 ? 0 : sec * 1000000 + (long)usec;
  if (sec >= 0 && timeout == 0) timeout = 1;
  if (__syscall(515, 1, (long)lock_word, (unsigned)oldval, timeout, 0, 0) == 0) return 0;
  if (errno == ETIMEDOUT) return 1;
  if (errno == EINTR) return 2;
  return -1;
}

int futex_wake(int *lock_word, int n) { return (int)__syscall(516, 1 | (n > 1 ? 0x100 : 0), (long)lock_word, 0, 0, 0, 0); }
#endif
