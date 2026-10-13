#include <signal.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include "libsa.h"

static struct sigaction actions[NSIG];
static sigset_t current_mask;
static int tramp_registered;

typedef struct {
  uint8_t fxsave[512];
  sigset_t uc_sigmask;
} context_prefix;

int sigemptyset(sigset_t *s) { memset(s, 0, sizeof *s); return 0; }
int sigfillset(sigset_t *s) { memset(s, 0xff, sizeof *s); return 0; }

int sigaddset(sigset_t *s, int sig) {
  if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
  s->__val[(sig - 1) / 64] |= 1ul << ((sig - 1) % 64);
  return 0;
}

int sigdelset(sigset_t *s, int sig) {
  if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
  s->__val[(sig - 1) / 64] &= ~(1ul << ((sig - 1) % 64));
  return 0;
}

int sigismember(const sigset_t *s, int sig) {
  if (sig <= 0 || sig >= NSIG) return 0;
  return (s->__val[(sig - 1) / 64] >> ((sig - 1) % 64)) & 1;
}

int sigprocmask(int how, const sigset_t *set, sigset_t *old) {
  if (old) *old = current_mask;
  if (!set) return 0;
  for (int i = 0; i < 16; i++) {
    if (how == SIG_BLOCK) current_mask.__val[i] |= set->__val[i];
    else if (how == SIG_UNBLOCK) current_mask.__val[i] &= ~set->__val[i];
    else current_mask.__val[i] = set->__val[i];
  }
  sigdelset(&current_mask, SIGKILL);
  sigdelset(&current_mask, SIGSTOP);
  return 0;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old) { return sigprocmask(how, set, old); }
int sigpending(sigset_t *s) { return sigemptyset(s); }

static void default_action(int sig, siginfo_t *info, void *uc) {
  (void)uc;
  if (sig == SIGCHLD || sig == SIGWINCH || sig == SIGURG || sig == SIGCONT) return;
  fprintf(stderr, "libsa: signal %d (%s) at %p, no handler\n", sig, strsignal(sig), info ? info->si_addr : 0);
  _exit(128 + sig);
}

void _sigtramp(int sig, siginfo_t *info, void *uc) {
  context_prefix *ctx = uc;
  struct sigaction *sa = &actions[sig];
  ctx->uc_sigmask = current_mask;
  for (int i = 0; i < 16; i++) current_mask.__val[i] |= sa->sa_mask.__val[i];
  if (!(sa->sa_flags & SA_NODEFER)) sigaddset(&current_mask, sig);
  if (sa->sa_handler == SIG_DFL) default_action(sig, info, uc);
  else if (sa->sa_handler != SIG_IGN) {
    if (sa->sa_flags & SA_SIGINFO) sa->sa_sigaction(sig, info, uc);
    else sa->sa_handler(sig);
  }
  if (sa->sa_flags & SA_RESETHAND) sa->sa_handler = SIG_DFL;
  current_mask = ctx->uc_sigmask;
  __syscall(SYS_sigreturn, (long)uc, 0, 0, 0, 0, 0);
}

int sigaction(int sig, const struct sigaction *sa, struct sigaction *old) {
  if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
  if (old) *old = actions[sig];
  if (sa) actions[sig] = *sa;
  if (!tramp_registered) {
    struct { void *handler, *tramp; unsigned mask; int flags; } darwin = {0, (void *)_sigtramp, 0, 0};
    __syscall(SYS_sigaction, sig, (long)&darwin, 0, 0, 0, 0);
    tramp_registered = 1;
  }
  return 0;
}

sighandler_t signal(int sig, sighandler_t handler) {
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = handler;
  if (sigaction(sig, &sa, &old) < 0) return SIG_ERR;
  return old.sa_handler;
}

int sigaltstack(const stack_t *ss, stack_t *old) {
  (void)ss;
  if (old) memset(old, 0, sizeof *old);
  return 0;
}

int raise(int sig) {
  if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
  if (sigismember(&current_mask, sig)) return 0;
  siginfo_t info;
  memset(&info, 0, sizeof info);
  info.si_signo = sig;
  struct sigaction *sa = &actions[sig];
  if (sa->sa_handler == SIG_IGN) return 0;
  if (sa->sa_handler == SIG_DFL) { default_action(sig, &info, 0); return 0; }
  sigset_t saved = current_mask;
  if (!(sa->sa_flags & SA_NODEFER)) sigaddset(&current_mask, sig);
  if (sa->sa_flags & SA_SIGINFO) {
    static uint8_t context[1024] __attribute__((aligned(16)));
    memset(context, 0, sizeof context);
    sa->sa_sigaction(sig, &info, context);
  } else
    sa->sa_handler(sig);
  current_mask = saved;
  return 0;
}

int kill(pid_t pid, int sig) {
  if (pid == 1 || pid == 0 || pid == -1) return raise(sig);
  errno = ESRCH;
  return -1;
}

int killpg(pid_t pg, int sig) { return kill(pg, sig); }
int sigsuspend(const sigset_t *s) { (void)s; errno = EINTR; return -1; }
int sigwait(const sigset_t *s, int *sig) { (void)s; (void)sig; return ENOSYS; }

static const char *names[] = {"0", "Hangup", "Interrupt", "Quit", "Illegal instruction", "Trace/breakpoint trap",
                               "Aborted", "Bus error", "Floating point exception", "Killed", "User defined signal 1",
                               "Segmentation fault", "User defined signal 2", "Broken pipe", "Alarm clock",
                               "Terminated"};

char *strsignal(int sig) {
  if (sig > 0 && sig < 16) return (char *)names[sig];
  return "Unknown signal";
}
