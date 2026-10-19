#include <assert.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <lfp.h>
#include <pwd.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#define LOAD(name) __typeof__(&name) p_##name = (__typeof__(&name))dlsym(lib,#name); assert(p_##name)
int main(int argc,char **argv) {
    if (argc==2 && !strcmp(argv[1],"--check-fds")) {
        char byte;
        assert(read(9,&byte,1)==1 && byte=='K');
        errno=0;assert(fcntl(10,F_GETFD)==-1 && errno==EBADF);
        return 0;
    }
    if (argc==2 && !strcmp(argv[1],"--check-environment")) {
        const char* value=getenv("NYXT_SPAWN_TEST");
        puts(value?value:"EMPTY");return 0;
    }
    struct passwd pw,*found;char account[128];
    assert(getpwuid_r(501,&pw,account,sizeof account,&found)==0 && found==&pw);
    assert(pw.pw_uid==501 && pw.pw_gid==20 && !strcmp(pw.pw_name,"darterfly"));
    assert(!strcmp(pw.pw_dir,"/Users/darterfly"));
    assert(getpwnam_r("darterfly",&pw,account,sizeof account,&found)==0 && found==&pw);
    assert(getpwuid_r(501,&pw,account,1,&found)==ERANGE && !found);
    assert(getpwuid_r(777,&pw,account,sizeof account,&found)==0 && !found);
    struct group* group=getgrgid(20);
    assert(group && !strcmp(group->gr_name,"staff") && group->gr_gid==20);
    assert(group->gr_mem && !strcmp(group->gr_mem[0],"darterfly") && !group->gr_mem[1]);
    assert(getgrnam("staff")->gr_gid==20 && getgrgid(0)->gr_gid==0);
    assert(!getgrgid(777) && !getgrnam("missing-account"));
    const char *dir="/tmp/nyxt-inputs";
    mkdir(dir,0700);
    unlink("/tmp/nyxt-inputs/link");
    assert(symlink("target", "/tmp/nyxt-inputs/link")==0);
    int fd=open(dir,O_RDONLY|O_DIRECTORY);assert(fd>=0);
    char buf[40];memset(buf,'!',sizeof buf);
    assert(readlinkat(fd,"link",buf,3)==3 && !memcmp(buf,"tar!",4));
    assert(readlinkat(fd,"link",buf,sizeof buf)==6 && !memcmp(buf,"target",6));
    assert(readlinkat(-1,"/tmp/nyxt-inputs/link",buf,sizeof buf)==6);
    errno=0;assert(readlinkat(fd,".",buf,sizeof buf)==-1 && errno==EINVAL);
    errno=0;assert(readlinkat(-1,"link",buf,sizeof buf)==-1 && errno==EBADF);
    errno=0;assert(readlinkat(fd,"link",buf,0)==-1 && errno==EINVAL);
    close(fd);
    DIR *stream=opendir(dir);assert(stream);
    struct dirent first,*result;errno=ERANGE;
    assert(readdir_r(stream,&first,&result)==0 && result==&first && errno==ERANGE);
    long at=telldir(stream);assert(at>0);
    seekdir(stream,0);assert(readdir_r(stream,&first,&result)==0 && result);
    assert(telldir(stream)==at);closedir(stream);
    char tokens[]="::alpha:beta::",other[]="one,two",*save=0,*save2=0;
    assert(!strcmp(strtok_r(tokens,":",&save),"alpha"));
    assert(!strcmp(strtok_r(other,",",&save2),"one"));
    assert(!strcmp(strtok_r(0,":",&save),"beta"));
    assert(!strtok_r(0,":",&save));
    assert(!strcmp(strtok_r(0,",",&save2),"two"));
    assert(confstr(_CS_PATH,0,0)==14);
    memset(buf,'!',sizeof buf);assert(confstr(_CS_PATH,buf,2)==14);
    assert(buf[0]=='/' && buf[1]==0 && buf[2]=='!');
    errno=0;assert(confstr(-1,buf,sizeof buf)==0 && errno==EINVAL);
    int pipes[2], on=1, off=0;
    assert(pipe(pipes)==0);
    assert(ioctl(pipes[0],FIONBIO,&on)==0);
    assert(fcntl(pipes[0],F_GETFL)&O_NONBLOCK);
    errno=0;assert(read(pipes[0],buf,1)==-1 && errno==EAGAIN);
    assert(ioctl(pipes[0],FIONBIO,&off)==0);
    assert(!(fcntl(pipes[0],F_GETFL)&O_NONBLOCK));
    errno=0;assert(ioctl(-1,FIONBIO,&on)==-1 && errno==EBADF);
    close(pipes[0]);close(pipes[1]);
    puts("[NYXT INPUTS LIBSA PASS]");
    void *lib=dlopen("/usr/lib/libfixposix.so",RTLD_NOW|RTLD_GLOBAL);
    if (!lib) { fprintf(stderr,"libfixposix: %s\n",dlerror());return 1; }
    LOAD(lfp_spawn);LOAD(lfp_spawn_file_actions_init);
    LOAD(lfp_spawn_file_actions_addopen);LOAD(lfp_spawn_file_actions_destroy);
    LOAD(lfp_spawn_file_actions_addkeep);
    LOAD(lfp_spawnattr_setflags);LOAD(lfp_spawnattr_setuid);
    LOAD(lfp_spawnattr_init);LOAD(lfp_spawnattr_setcwd);LOAD(lfp_spawnattr_destroy);
    lfp_spawn_file_actions_t files;lfp_spawnattr_t attr;
    assert(p_lfp_spawn_file_actions_init(&files)==0);
    assert(p_lfp_spawn_file_actions_addopen(&files,1,"version",O_WRONLY|O_CREAT|O_TRUNC,0600)==0);
    assert(p_lfp_spawnattr_init(&attr)==0);
    assert(p_lfp_spawnattr_setcwd(&attr,dir)==0);
    pid_t child;char *args[]={"pkg-config","--version",0};
    assert(p_lfp_spawn(&child,"/usr/bin/pkg-config",args,environ,&files,&attr)==0);
    int status;assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    fd=open("/tmp/nyxt-inputs/version",O_RDONLY);assert(fd>=0);
    memset(buf,0,sizeof buf);assert(read(fd,buf,sizeof buf-1)>0);close(fd);
    assert(!strcmp(buf,"2.5.1\n"));
    errno=0;assert(p_lfp_spawn(&child,"/missing-nyxt-input",args,environ,&files,&attr)==-1 && errno==ENOENT);
    assert(p_lfp_spawnattr_destroy(&attr)==0);
    assert(p_lfp_spawn_file_actions_destroy(&files)==0);
    assert(p_lfp_spawnattr_init(&attr)==0);
    assert(p_lfp_spawnattr_setflags(&attr,LFP_SPAWN_SETCTTY)==0);
    errno=0;assert(p_lfp_spawn(&child,"/usr/bin/pkg-config",args,environ,0,&attr)==-1 && errno==ENOTSUP);
    assert(p_lfp_spawnattr_setflags(&attr,0)==0);
    assert(p_lfp_spawnattr_setuid(&attr,geteuid()+1)==0);
    errno=0;assert(p_lfp_spawn(&child,"/usr/bin/pkg-config",args,environ,0,&attr)==-1 && errno==ENOTSUP);
    assert(p_lfp_spawnattr_destroy(&attr)==0);
    fd=open("/tmp/nyxt-inputs/keep",O_RDWR|O_CREAT|O_TRUNC,0600);
    assert(fd>=0 && write(fd,"K",1)==1 && lseek(fd,0,SEEK_SET)==0);
    assert(dup2(fd,9)==9 && dup2(fd,10)==10);close(fd);
    assert(fcntl(9,F_SETFD,FD_CLOEXEC)==0);
    assert(p_lfp_spawn_file_actions_init(&files)==0);
    assert(p_lfp_spawn_file_actions_addkeep(&files,9)==0);
    char *check[]={"nyxt-inputs-probe","--check-fds",0};
    assert(p_lfp_spawn(&child,"/tmp/nyxt-inputs-probe",check,environ,&files,0)==0);
    assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    close(9);close(10);
    assert(p_lfp_spawn_file_actions_destroy(&files)==0);
    assert(dlclose(lib)==0);
    puts("[NYXT INPUTS FIXPOSIX SPAWN PASS]");
    return 0;
}
