#pragma once
#include <stdint.h>
#include <stddef.h>

#define SYS_exit 1
#define SYS_read 3
#define SYS_write 4
#define SYS_getpid 20
#define SYS_kill 37
#define SYS_sigaction 46
#define SYS_sigprocmask 48
#define SYS_setitimer 83
#define SYS_getitimer 86
#define SYS_poll 230
#define SYS___semwait_signal 334
#define SYS___pthread_kill 328
#define SYS___pthread_sigmask 329
#define SYS_bsdthread_create 360
#define SYS_bsdthread_terminate 361
#define SYS_thread_selfid 372
#define SYS_ulock_wait 515
#define SYS_ulock_wake 516
#define SYS_munmap 73
#define SYS_mprotect 74
#define SYS_madvise 75
#define SYS_sigreturn 184
#define SYS_mmap 197

#define MACHDEP_set_cthread_self 3
#define MACHDEP_commpage 4
#define MACHDEP_console_ready 5
#define MACHDEP_kernel_file 6
#define MACHDEP_ramdisk 7
#define MACHDEP_boot_args 8
#define MACHDEP_vm_page_grab 9
#define MACHDEP_ml_io_map 10
#define MACHDEP_boot_video 11

long __syscall(long n, long a, long b, long c, long d, long e, long f);
long __machdep(long n, long a, long b);
void __libsa_stdio_init(void);
