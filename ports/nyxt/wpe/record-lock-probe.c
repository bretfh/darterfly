#include <sys/types.h>
#include <sys/wait.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
extern char **environ;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"lock probe line %d errno %d\n",__LINE__,errno); return 1; } } while (0)
static int lock(int fd,int command,int kind,long start,long length) {
    struct flock f={0}; f.l_type=kind;f.l_whence=SEEK_SET;f.l_start=start;f.l_len=length;
    return fcntl(fd,command,&f);
}
static pthread_t signal_target;
static volatile sig_atomic_t signals_seen;
static void notice(int signal) { (void)signal; ++signals_seen; }
static void *signal_storm(void *unused) {
    (void)unused;
    for (int i=0;i<1000;++i) { pthread_kill(signal_target,SIGUSR1);usleep(100); }
    return NULL;
}
static int descriptor_signals(void) {
    struct sigaction action={0};action.sa_handler=notice;sigemptyset(&action.sa_mask);
    CHECK(sigaction(SIGUSR1,&action,NULL)==0);
    signal_target=pthread_self();pthread_t worker;
    CHECK(pthread_create(&worker,NULL,signal_storm,NULL)==0);
    for(int i=0;i<500;++i) {
        int fds[2];CHECK(pipe(fds)==0);
        CHECK(fcntl(fds[0],F_SETFL,O_NONBLOCK)==0);
        CHECK(fcntl(fds[0],F_GETFL)&O_NONBLOCK);
        /* close may be interrupted by the service transport: defer the test
           signal while releasing, rather than retrying an ambiguous close. */
        sigset_t set,previous;sigfillset(&set);
        CHECK(pthread_sigmask(SIG_BLOCK,&set,&previous)==0);
        CHECK(close(fds[0])==0 && close(fds[1])==0);
        CHECK(pthread_sigmask(SIG_SETMASK,&previous,NULL)==0);
    }
    CHECK(pthread_join(worker,NULL)==0 && signals_seen>0);
    sigset_t current;CHECK(pthread_sigmask(SIG_SETMASK,NULL,&current)==0);
    CHECK(sigismember(&current,SIGUSR1)==0);
    puts("NATIVE DESCRIPTOR SIGNALS PASS");return 0;
}
int main(int argc,char **argv) {
    int fd=open("/tmp/nyxt-record-lock-test",O_RDWR|O_CREAT,0600);CHECK(fd>=0);
    if(argc>1) {
        struct flock f={0};f.l_type=F_WRLCK;f.l_start=128;f.l_len=1;
        CHECK(fcntl(fd,F_GETLK,&f)==0);
        if(!strcmp(argv[1],"blocked")) {
            CHECK(f.l_type==F_WRLCK && f.l_pid==getppid());
            CHECK(lock(fd,F_SETLK,F_WRLCK,128,1)==-1 && errno==EAGAIN);
        } else {
            CHECK(f.l_type==F_UNLCK);
            CHECK(lock(fd,F_SETLK,F_WRLCK,128,1)==0);
        }
        close(fd);return 0;
    }
    CHECK(lock(fd,F_SETLK,F_WRLCK,100,100)==0);
    char *child[]={argv[0],"blocked",NULL};pid_t pid;int status;
    CHECK(posix_spawn(&pid,argv[0],NULL,NULL,child,environ)==0);
    CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0);
    /* Closing another descriptor to the same inode releases our record locks. */
    int second=open("/tmp/nyxt-record-lock-test",O_RDONLY);CHECK(second>=0);close(second);
    child[1]="available";
    CHECK(posix_spawn(&pid,argv[0],NULL,NULL,child,environ)==0);
    CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0);
    CHECK(lock(fd,F_SETLK,F_WRLCK,0,0)==0);
    close(fd);unlink("/tmp/nyxt-record-lock-test");CHECK(descriptor_signals()==0);puts("NATIVE RECORD LOCKS PASS");return 0;
}
