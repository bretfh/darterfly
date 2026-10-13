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

int sb_GetTID() { return 1; }

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
  if (gencgc_handle_wp_violation(context, addr)) return;
  if (!handle_guard_page_triggered(context, addr)) lisp_memory_fault_error(context, addr);
}

void os_install_interrupt_handlers(void) {
  if (INSTALL_SIG_MEMORY_FAULT_HANDLER) ll_install_handler(SIG_MEMORY_FAULT, sigsegv_handler);
}
