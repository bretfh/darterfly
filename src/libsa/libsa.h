#pragma once
#include <stdint.h>
#include <stddef.h>

#define SYS_exit 1
#define SYS_read 3
#define SYS_write 4
#define SYS_getpid 20
#define SYS_kill 37
#define SYS_sigaction 46
#define SYS_munmap 73
#define SYS_mprotect 74
#define SYS_madvise 75
#define SYS_sigreturn 184
#define SYS_mmap 197

#define MACHDEP_set_cthread_self 3
#define MACHDEP_commpage 4
#define MACHDEP_console_ready 5
#define MACHDEP_kernel_file 6

long __syscall(long n, long a, long b, long c, long d, long e, long f);
long __machdep(long n, long a);
void __libsa_stdio_init(void);
