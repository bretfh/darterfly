#pragma once
#include <sys/types.h>
#include <time.h>
#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGILL 4
#define SIGTRAP 5
#define SIGABRT 6
#define SIGIOT SIGABRT
#define SIGBUS 7
#define SIGFPE 8
#define SIGKILL 9
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGUSR2 12
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGSTKFLT 16
#define SIGCHLD 17
#define SIGCONT 18
#define SIGSTOP 19
#define SIGTSTP 20
#define SIGTTIN 21
#define SIGTTOU 22
#define SIGURG 23
#define SIGXCPU 24
#define SIGXFSZ 25
#define SIGVTALRM 26
#define SIGPROF 27
#define SIGWINCH 28
#define SIGIO 29
#define SIGPOLL SIGIO
#define SIGPWR 30
#define SIGSYS 31
#define NSIG 65
#define _NSIG NSIG
#define SIGRTMIN 34
#define SIGRTMAX 64
typedef struct { unsigned long __val[16]; } sigset_t;
typedef int sig_atomic_t;
union sigval { int sival_int; void *sival_ptr; };
typedef struct {
  int si_signo, si_errno, si_code, __pad;
  union {
    struct { pid_t si_pid; uid_t si_uid; int si_status; } __kill;
    void *si_addr;
    char __size[112];
  } __u;
} siginfo_t;
#define si_addr __u.si_addr
#define si_pid __u.__kill.si_pid
#define si_uid __u.__kill.si_uid
#define si_status __u.__kill.si_status
typedef void (*sighandler_t)(int);
#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIG_ERR ((sighandler_t)-1)
struct sigaction {
  union {
    void (*sa_handler)(int);
    void (*sa_sigaction)(int, siginfo_t *, void *);
  } __sa;
  sigset_t sa_mask;
  int sa_flags;
  void (*sa_restorer)(void);
};
#define sa_handler __sa.sa_handler
#define sa_sigaction __sa.sa_sigaction
#define SA_NOCLDSTOP 1
#define SA_NOCLDWAIT 2
#define SA_SIGINFO 4
#define SA_ONSTACK 0x08000000
#define SA_RESTART 0x10000000
#define SA_NODEFER 0x40000000
#define SA_RESETHAND 0x80000000
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
typedef struct { void *ss_sp; int ss_flags; size_t ss_size; } stack_t;
#define SS_ONSTACK 1
#define SS_DISABLE 2
#define MINSIGSTKSZ 2048
#define SIGSTKSZ 8192
#define SEGV_MAPERR 1
#define SEGV_ACCERR 2
#define ILL_ILLOPC 1
#define TRAP_BRKPT 1
#define FPE_INTDIV 1
#define FPE_INTOVF 2
#define FPE_FLTDIV 3
#define FPE_FLTOVF 4
#define FPE_FLTUND 5
#define FPE_FLTRES 6
#define FPE_FLTINV 7
#define FPE_FLTSUB 8
#define CLD_EXITED 1
int sigaction(int, const struct sigaction *, struct sigaction *);
sighandler_t signal(int, sighandler_t);
int sigemptyset(sigset_t *);
int sigfillset(sigset_t *);
int sigaddset(sigset_t *, int);
int sigdelset(sigset_t *, int);
int sigismember(const sigset_t *, int);
int sigprocmask(int, const sigset_t *, sigset_t *);
int pthread_sigmask(int, const sigset_t *, sigset_t *);
int sigpending(sigset_t *);
int sigsuspend(const sigset_t *);
int sigwait(const sigset_t *, int *);
int sigaltstack(const stack_t *, stack_t *);
int kill(pid_t, int);
int killpg(pid_t, int);
int raise(int);
