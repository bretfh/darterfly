#include <stdlib.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/syscall.h>

typedef caddr_t os_vm_address_t;
typedef size_t os_vm_size_t;
typedef off_t os_vm_offset_t;
typedef int os_vm_prot_t;

#include "target-arch-os.h"
#include "target-arch.h"

#define SIG_MEMORY_FAULT SIGSEGV
#define SIG_STOP_FOR_GC (SIGUSR2)
