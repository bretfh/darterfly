/* Darterfly port of libfixposix's spawn boundary. Attribute and file-action
 * objects remain upstream's; child creation uses the shared posix_spawn. */
#include <lfp/spawn.h>
#include <spawn.h>
#include <errno.h>
#include <unistd.h>
int lfp_darter_file_actions(const lfp_spawn_file_actions_t *,
                           posix_spawn_file_actions_t *);
static int spawn_child(int search, pid_t *pid, const char *path,
                       char *const argv[], char *const envp[],
                       const lfp_spawn_file_actions_t *files,
                       const lfp_spawnattr_t *attr)
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t native;
    short flags = POSIX_SPAWN_SETSIGMASK;
    sigset_t empty;
    int error;
    if (!pid || !path || !argv) { errno=EINVAL; return -1; }
    error=posix_spawn_file_actions_init(&actions);
    if (error) { errno=error; return -1; }
    error=posix_spawnattr_init(&native);
    if (error) goto done;
    sigemptyset(&empty);
    error=posix_spawnattr_setsigmask(&native, &empty);
    if (error) goto finish;
    if (attr) {
        const unsigned supported=LFP_SPAWN_SETSIGMASK|LFP_SPAWN_SETSIGDEFAULT|
            LFP_SPAWN_SETPGROUP|LFP_SPAWN_RESETIDS|LFP_SPAWN_SETUID|
            LFP_SPAWN_SETGID|LFP_SPAWN_SETCWD|LFP_SPAWN_SETSID|LFP_SPAWN_USEVFORK;
        if ((attr->flags & ~supported) ||
            ((attr->flags & LFP_SPAWN_SETUID) && attr->uid != geteuid()) ||
            ((attr->flags & LFP_SPAWN_SETGID) && attr->gid != getegid())) {
            error=ENOTSUP; goto finish;
        }
        if (attr->flags & LFP_SPAWN_SETSIGMASK) {
            error=posix_spawnattr_setsigmask(&native, &attr->sigmask);
            if (error) goto finish;
        }
        if (attr->flags & LFP_SPAWN_SETSIGDEFAULT) {
            flags |= POSIX_SPAWN_SETSIGDEF;
            error=posix_spawnattr_setsigdefault(&native, &attr->sigdefault);
            if (error) goto finish;
        }
        if (attr->flags & LFP_SPAWN_SETPGROUP) {
            flags |= POSIX_SPAWN_SETPGROUP;
            error=posix_spawnattr_setpgroup(&native, attr->pgroup);
            if (error) goto finish;
        }
        if (attr->flags & LFP_SPAWN_RESETIDS) flags |= POSIX_SPAWN_RESETIDS;
        if (attr->flags & LFP_SPAWN_SETSID) flags |= POSIX_SPAWN_SETSID;
        if (attr->flags & LFP_SPAWN_SETCWD) {
            error=posix_spawn_file_actions_addchdir_np(&actions,attr->chdir_path);
            if (error) goto finish;
        }
    }
    if (files && files->keep_descriptors) flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
    error=lfp_darter_file_actions(files,&actions);
    if (error) goto finish;
    error=posix_spawnattr_setflags(&native,flags);
    if (!error) error=(search ? posix_spawnp : posix_spawn)
        (pid,path,&actions,&native,argv,envp ? envp : environ);
finish:
    posix_spawnattr_destroy(&native);
done:
    posix_spawn_file_actions_destroy(&actions);
    if (error) { errno=error; return -1; }
    return 0;
}
DSO_PUBLIC int lfp_spawn(pid_t *pid,const char *path,char *const argv[],
    char *const envp[],const lfp_spawn_file_actions_t *files,
    const lfp_spawnattr_t *attr)
{ return spawn_child(0,pid,path,argv,envp,files,attr); }
DSO_PUBLIC int lfp_spawnp(pid_t *pid,const char *path,char *const argv[],
    char *const envp[],const lfp_spawn_file_actions_t *files,
    const lfp_spawnattr_t *attr)
{ return spawn_child(1,pid,path,argv,envp,files,attr); }
