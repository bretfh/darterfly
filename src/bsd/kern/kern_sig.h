#pragma once
#include <stdint.h>

#define NSIG 65
#define SIGINT 2
#define SIGILL 4
#define SIGTRAP 5
#define SIGBUS 7
#define SIGFPE 8
#define SIGKILL 9
#define SIGSEGV 11
#define SIGALRM 14
#define SIGSTOP 19
#define SA_NODEFER 0x40000000
#define SA_RESETHAND 0x80000000u
#define SIG_IGN_VALUE 1
#define EINTR 4
#define ETIMEDOUT 110
#define EAGAIN 11
#define sigmask(sig) (1ull << ((sig) - 1))

struct sigacts { uint64_t handler, mask; uint32_t flags; };

extern uint64_t p_siglist, sigtramp;
extern int sigtrace;
struct thread;
void psignal_thread(struct thread *t, int sig);
extern struct sigacts p_sigacts[NSIG];

void psignal(int sig);
int issignal(void);
int tsleep(int (*ready)(void), uint64_t event, uint64_t deadline);
void getitimer_real(int64_t *out);
void setitimer_real(const int64_t *in, int64_t *old);
uint64_t deadline_after(int64_t sec, int64_t nsec);
