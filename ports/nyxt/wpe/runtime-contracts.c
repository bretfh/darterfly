/* Small qualification probes, not a WebKit execution test.
 * Exit 0: contract observed; 1: contract gap; 2: setup failed.
 */
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <sched.h>
#include <sys/wait.h>
#include <math.h>
#include <float.h>
#include <sys/ucontext.h>
#include <stddef.h>
#include <poll.h>
_Static_assert(offsetof(ucontext_t, uc_sigmask) == 512, "signal mask ABI");
_Static_assert(offsetof(ucontext_t, uc_mcontext) == 640, "saved registers ABI");
_Static_assert(offsetof(mcontext_t, rsp) == 160, "saved stack ABI");
_Static_assert(sizeof(ucontext_t) == 816, "signal frame ABI");

static long long ns(struct timespec t)
{
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static int stack_bounds(void)
{
    pthread_attr_t attr;
    void *base = 0;
    size_t size = 0;
    char marker;
    if (pthread_getattr_np(pthread_self(), &attr) ||
        pthread_attr_getstack(&attr, &base, &size)) return 2;
    pthread_attr_destroy(&attr);
    return !((uintptr_t)&marker >= (uintptr_t)base &&
             (uintptr_t)&marker - (uintptr_t)base < size);
}

static int spawn_attributes(void)
{
    posix_spawnattr_t attr;
    sigset_t reset;
    if (posix_spawnattr_init(&attr)) return 2;
    sigemptyset(&reset);
    sigaddset(&reset, SIGCHLD);
    int flags = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);
    int defaults = posix_spawnattr_setsigdefault(&attr, &reset);
    posix_spawnattr_destroy(&attr);
    return !!(flags || defaults);
}

static int monotonic_condition(void)
{
    pthread_condattr_t attr;
    pthread_cond_t cond;
    pthread_mutex_t mutex;
    struct timespec start, deadline, end;
    if (pthread_condattr_init(&attr) ||
        pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) ||
        pthread_cond_init(&cond, &attr) ||
        pthread_mutex_init(&mutex, 0)) return 2;
    pthread_mutex_lock(&mutex);
    clock_gettime(CLOCK_MONOTONIC, &start);
    deadline = start;
    deadline.tv_nsec += 100000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_nsec -= 1000000000;
        deadline.tv_sec++;
    }
    int status = pthread_cond_timedwait(&cond, &mutex, &deadline);
    clock_gettime(CLOCK_MONOTONIC, &end);
    pthread_mutex_unlock(&mutex);
    pthread_mutex_destroy(&mutex);
    pthread_cond_destroy(&cond);
    pthread_condattr_destroy(&attr);
    /* Wide tolerance: detect immediate expiry, not scheduler precision. */
    return !(status == ETIMEDOUT && ns(end) - ns(start) >= 50000000);
}

static volatile sig_atomic_t delivered;
static pthread_t recipient;
static int sender_status;
static void handler(int signal) { (void)signal; delivered = 1; }
static void *send_signal(void *unused)
{
    (void)unused;
    usleep(100000);
    sender_status = pthread_kill(recipient, SIGUSR1);
    return 0;
}

static int suspend_mask(void)
{
    struct sigaction action;
    sigset_t blocked, old, temporary;
    pthread_t thread;
    memset(&action, 0, sizeof action);
    action.sa_handler = handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGUSR1, &action, 0)) return 2;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGUSR1);
    if (pthread_sigmask(SIG_BLOCK, &blocked, &old)) return 2;
    recipient = pthread_self();
    if (pthread_create(&thread, 0, send_signal, 0)) return 2;
    temporary = old;
    sigdelset(&temporary, SIGUSR1);
    int status = sigsuspend(&temporary);
    int saved_errno = errno;
    int observed = delivered;
    pthread_join(thread, 0);
    pthread_sigmask(SIG_SETMASK, &old, 0);
    return !(status == -1 && saved_errno == EINTR && observed &&
             sender_status == 0);
}


static int spawn_child(void)
{
    sigset_t mask;
    struct sigaction a, b;
    if (pthread_sigmask(SIG_SETMASK, 0, &mask) ||
        sigaction(SIGUSR1, 0, &a) || sigaction(SIGUSR2, 0, &b)) return 2;
    return !(sigismember(&mask, SIGUSR1) &&
             !sigismember(&mask, SIGUSR2) && a.sa_handler == SIG_DFL &&
             b.sa_handler == SIG_IGN);
}

static int spawn_inherit(const char *path)
{
    posix_spawnattr_t attr;
    sigset_t mask, defaults;
    pid_t pid;
    int status;
    char *args[] = {(char *)path, "spawn-child", 0};
    char *env[] = {0};
    signal(SIGUSR1, SIG_IGN);
    signal(SIGUSR2, SIG_IGN);
    sigemptyset(&mask); sigaddset(&mask, SIGUSR2);
    pthread_sigmask(SIG_SETMASK, &mask, 0);
    sigemptyset(&mask); sigaddset(&mask, SIGUSR1);
    sigemptyset(&defaults); sigaddset(&defaults, SIGUSR1);
    if (posix_spawnattr_init(&attr) ||
        posix_spawnattr_setflags(&attr,
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) ||
        posix_spawnattr_setsigmask(&attr, &mask) ||
        posix_spawnattr_setsigdefault(&attr, &defaults)) return 2;
    int r = posix_spawn(&pid, path, 0, &attr, args, env);
    posix_spawnattr_destroy(&attr);
    if (r) return 2;
    return !(waitpid(pid, &status, 0) == pid && status == 0);
}

static sem_t stopped, resumed;
static atomic_int running, ticks;
static volatile sig_atomic_t in_handler, nested, bad_context;
static void gc_handler(int sig, siginfo_t *info, void *context)
{
    (void)sig; (void)info;
    ucontext_t *uc = context;
    if (!uc || !uc->uc_mcontext.rip || !uc->uc_mcontext.rsp)
        bad_context = 1;
    if (in_handler) { nested++; return; }
    in_handler = 1;
    sem_post(&stopped);
    sigset_t temporary;
    sigfillset(&temporary);
    sigdelset(&temporary, SIGUSR1);
    sigsuspend(&temporary);
    in_handler = 0;
    sem_post(&resumed);
}
static void *gc_worker(void *arg)
{
    (void)arg;
    while (atomic_load(&running)) {
        atomic_fetch_add(&ticks, 1);
        sched_yield();
    }
    return 0;
}
static int gc_handshake(void)
{
    struct sigaction a;
    pthread_t worker;
    memset(&a, 0, sizeof a);
    a.sa_sigaction = gc_handler;
    a.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&a.sa_mask);
    sigaddset(&a.sa_mask, SIGUSR1);
    if (sigaction(SIGUSR1, &a, 0) || sem_init(&stopped, 0, 0) ||
        sem_init(&resumed, 0, 0)) return 2;
    atomic_store(&running, 1);
    if (pthread_create(&worker, 0, gc_worker, 0)) return 2;
    int ok = 1;
    for (int i = 0; i < 50; i++) {
        if (pthread_kill(worker, SIGUSR1) || sem_wait(&stopped)) return 2;
        int count = atomic_load(&ticks);
        usleep(1000);
        if (atomic_load(&ticks) != count) ok = 0;
        if (pthread_kill(worker, SIGUSR1) || sem_wait(&resumed)) return 2;
    }
    atomic_store(&running, 0);
    pthread_join(worker, 0);
    sem_destroy(&stopped); sem_destroy(&resumed);
    return !(ok && nested == 50 && !bad_context);
}


static unsigned fp_control(void)
{
    unsigned csr;
    __asm__ volatile("stmxcsr %0" : "=m"(csr));
    return csr;
}
static void *fp_worker(void *unused)
{
    (void)unused;
    return (void *)(long)((fp_control() & ~63u) != 0x7f80);
}
static int fenv_contract(void)
{
    unsigned short cw;
    __asm__ volatile("fnstcw %0" : "=m"(cw));
    if ((fp_control() & ~63u) != 0x1f80 || cw != 0x37f) return 1;
    volatile double zero = 0.;
    double nan = zero / zero;
    if (!isnan(nan)) return 1;
    unsigned csr = 0x7f80;
    __asm__ volatile("ldmxcsr %0" : : "m"(csr));
    pthread_t thread;
    void *result;
    if (pthread_create(&thread, NULL, fp_worker, NULL) ||
        pthread_join(thread, &result) || result) return 1;
    return (fp_control() & ~63u) != 0x7f80;
}

static int math_contract(void)
{
    volatile double a64 = 0x1.0000000000001p0;
    if (fma(a64, 0x1.fffffffffffffp-1, -1.) != 0x1.ffffffffffffep-54)
        return 1;
    a64 = 0x1p-1022;
    if (fma(a64, 0.5, -0x1p-1074) != 0x0.7ffffffffffffp-1022)
        return 1;
    a64 = 0x1.fffffffffffffp1023;
    if (fma(a64, 2., -a64) != a64) return 1;
    int e;
    volatile long double x = 12.0L;
    if (frexpl(x, &e) != 0.75L || e != 4) return 1;
    x = -LDBL_MIN;
    if (frexpl(x, &e) != -0.5L || e != LDBL_MIN_EXP) return 1;
    x = LDBL_MIN * 0.5L;
    if (frexpl(x, &e) != 0.5L || e != LDBL_MIN_EXP - 1) return 1;
    x = -0.0L;
    if (frexpl(x, &e) != 0.0L || e || !signbit(frexpl(x, &e))) return 1;
    x = HUGE_VALL;
    if (!isinf(frexpl(x, &e))) return 1;
    x = 1.0L;
    long double a = atan2l(x, x);
    if (a < 0.785398163397448L || a > 0.785398163397449L) return 1;
    x = 3.0L;
    if (hypotl(x, 4.0L) != 5.0L) return 1;
    x = LDBL_MAX / 4.0L;
    if (!isfinite(hypotl(x, x))) return 1;
    x = HUGE_VALL;
    if (!isinf(hypotl(x, NAN))) return 1;
    x = 0.0L;
    if (hypotl(x, -0.0L) != 0.0L || signbit(hypotl(x, -0.0L))) return 1;
    volatile float f = 0.0f;
    return !(expf(f) == 1.0f && atan2f(f, 1.0f) == 0.0f);
}

static int child_notification(const char *path)
{
    struct sigaction action;
    pid_t pid;
    int status;
    memset(&action, 0, sizeof action);
    action.sa_handler = handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGCHLD, &action, 0)) return 2;
    char *args[] = {(char *)path, "delayed-child", 0};
    char *env[] = {0};
    if (posix_spawn(&pid, path, 0, 0, args, env)) return 2;
    for (int i = 0; i < 1000 && !delivered; i++) usleep(1000);
    int got = delivered;
    if (waitpid(pid, &status, 0) != pid) return 2;
    return !(got && status == 0);
}


static int native_signal_child(void)
{
    signal(SIGUSR1, handler);
    if (write(1, "R", 1) != 1) return 2;
    for (int i=0;i<2000 && !delivered;i++) usleep(1000);
    return !delivered;
}
static int native_signal(const char *path)
{
    int fds[2], status;
    pid_t pid;
    posix_spawn_file_actions_t actions;
    if (pipe(fds) || posix_spawn_file_actions_init(&actions) ||
        posix_spawn_file_actions_adddup2(&actions,fds[1],1)) return 2;
    char *args[]={(char *)path,"native-signal-child",0};
    char *env[]={0};
    int result=posix_spawn(&pid,path,&actions,0,args,env);
    posix_spawn_file_actions_destroy(&actions);
    if (result) return 2;
    close(fds[1]);
    char ready;
    if (read(fds[0],&ready,1)!=1 || ready!='R') return 2;
    close(fds[0]);
    if (kill(pid,SIGUSR1)) return 1;
    return !(waitpid(pid,&status,0)==pid && status==0);
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "native-signal")) return native_signal(argv[0]);
    if (!strcmp(argv[1], "native-signal-child")) return native_signal_child();
    if (!strcmp(argv[1], "fenv")) return fenv_contract();
    if (!strcmp(argv[1], "math")) return math_contract();
    if (!strcmp(argv[1], "child-notification")) return child_notification(argv[0]);
    if (!strcmp(argv[1], "delayed-child")) { usleep(100000); return 0; }
    if (!strcmp(argv[1], "spawn-child")) return spawn_child();
    if (!strcmp(argv[1], "spawn-inherit")) return spawn_inherit(argv[0]);
    if (!strcmp(argv[1], "gc-handshake")) return gc_handshake();
    if (!strcmp(argv[1], "stack")) return stack_bounds();
    if (!strcmp(argv[1], "spawn")) return spawn_attributes();
    if (!strcmp(argv[1], "cond")) return monotonic_condition();
    if (!strcmp(argv[1], "suspend")) return suspend_mask();
    return 2;
}
