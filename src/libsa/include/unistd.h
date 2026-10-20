#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/types.h>
#define STDIN_FILENO 0
#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4
#define _SC_GETPW_R_SIZE_MAX 70
#define _SC_ARG_MAX 0
#define _POSIX_ARG_MAX 4096
#define _SC_PAGESIZE 30
#define _SC_PAGE_SIZE _SC_PAGESIZE
#define _SC_NPROCESSORS_CONF 83
#define _SC_NPROCESSORS_ONLN 84
/* Currently unsupported: sysconf returns -1/EINVAL, never a guessed size. */
#define _SC_PHYS_PAGES 85
#define _SC_CLK_TCK 2
extern char **environ;
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
ssize_t pread(int, void *, size_t, off_t);
ssize_t pwrite(int, const void *, size_t, off_t);
int close(int);
off_t lseek(int, off_t, int);
int dup(int);
int dup2(int, int);
int pipe(int[2]);
int isatty(int);
pid_t getpid(void);
pid_t getppid(void);
pid_t getpgrp(void);
int setpgid(pid_t, pid_t);
pid_t setsid(void);
pid_t getsid(pid_t);
pid_t tcgetpgrp(int);
uid_t getuid(void);
uid_t geteuid(void);
int setuid(uid_t);
int seteuid(uid_t);
gid_t getgid(void);
gid_t getegid(void);
int setegid(gid_t);
#define _CS_PATH 0
size_t confstr(int, char *, size_t);
long sysconf(int);
int getpagesize(void);
int access(const char *, int);
#define _PC_PATH_MAX 4
long pathconf(const char *, int);
int unlink(const char *);
int unlinkat(int, const char *, int);
int rmdir(const char *);
int chdir(const char *);
char *getcwd(char *, size_t);
ssize_t readlinkat(int, const char *, char *, size_t);
ssize_t readlink(const char *, char *, size_t);
int symlink(const char *, const char *);
int link(const char *, const char *);
int truncate(const char *, off_t);
int ftruncate(int, off_t);
int fsync(int);
unsigned sleep(unsigned);
unsigned alarm(unsigned);
int usleep(useconds_t);
pid_t fork(void);
int execv(const char *, char *const[]);
int execve(const char *, char *const[], char *const[]);
int execvp(const char *, char *const[]);
void _exit(int) __attribute__((noreturn));
char *ttyname(int);
int gethostname(char *, size_t);
long syscall(long, ...);
int fchown(int, uid_t, gid_t);
int lchown(const char *, uid_t, gid_t);
int chown(const char *, uid_t, gid_t);
int fchdir(int);
int close_range(unsigned, unsigned, int);
int getdtablesize(void);
int setpgrp(pid_t, pid_t);
int tcsetpgrp(int, pid_t);
#define F_ULOCK 0
#define F_LOCK 1
#define F_TLOCK 2
#define F_TEST 3
#define _POSIX_VDISABLE 0

#ifdef __cplusplus
}
#endif
