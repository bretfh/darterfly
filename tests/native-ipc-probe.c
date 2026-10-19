#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <poll.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define CHECK(x,n) do { if (!(x)) { printf("IPC failure %d errno=%d\n",n,errno); return n; } } while (0)
union control { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(2*sizeof(int))]; };

static int send_rights(int sock, int first, int second) {
    union control c = {0};
    struct iovec iov[2] = {{"AB",2},{"CD",2}};
    struct msghdr m = {0};
    m.msg_iov=iov; m.msg_iovlen=2; m.msg_control=c.bytes; m.msg_controllen=sizeof c;
    struct cmsghdr *h=CMSG_FIRSTHDR(&m);
    h->cmsg_level=SOL_SOCKET; h->cmsg_type=SCM_RIGHTS; h->cmsg_len=CMSG_LEN(2*sizeof(int));
    int fds[2]={first,second}; memcpy(CMSG_DATA(h),fds,sizeof fds);
    return sendmsg(sock,&m,MSG_NOSIGNAL);
}
static int child(void) {
    char bytes[4], data[2]; union control c = {0};
    struct iovec iov[2]={{bytes,1},{bytes+1,3}};
    struct msghdr m={0}; m.msg_iov=iov; m.msg_iovlen=2;
    m.msg_control=c.bytes; m.msg_controllen=sizeof c;
    struct pollfd p={3,POLLIN,0};
    CHECK(poll(&p,1,5000)==1 && (p.revents&POLLIN),11);
    CHECK(recvmsg(3,&m,MSG_CMSG_CLOEXEC)==4 && !memcmp(bytes,"ABCD",4),12);
    CHECK(m.msg_flags==0 && m.msg_controllen==CMSG_SPACE(2*sizeof(int)),13);
    struct cmsghdr *h=CMSG_FIRSTHDR(&m);
    CHECK(h && h->cmsg_type==SCM_RIGHTS && !CMSG_NXTHDR(&m,h),14);
    int fds[2]; memcpy(fds,CMSG_DATA(h),sizeof fds);
    CHECK(fcntl(fds[0],F_GETFD)==FD_CLOEXEC && fcntl(fds[1],F_GETFD)==FD_CLOEXEC,15);
    CHECK(read(fds[0],data,2)==2 && !memcmp(data,"cd",2),16);
    CHECK(write(fds[1],"OK",2)==2,17);
    close(fds[0]); close(fds[1]); close(3);
    return 0;
}
static int pair_test(const char *self, int type) {
    int channel[2], ack[2], status, fd, keep; pid_t pid;
    posix_spawn_file_actions_t a;
    CHECK(socketpair(AF_UNIX,type,0,channel)==0,21);
    CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,ack)==0,22);
    fd=open("/tmp/native-rights-artifact",O_CREAT|O_TRUNC|O_RDWR,0600);
    CHECK(fd>=0 && write(fd,"abcdef",6)==6 && lseek(fd,2,SEEK_SET)==2,23);
    CHECK((keep=dup(fd))>=0,24);
    CHECK(posix_spawn_file_actions_init(&a)==0,25);
    CHECK(posix_spawn_file_actions_adddup2(&a,channel[1],3)==0,26);
    CHECK(posix_spawn_file_actions_addclosefrom_np(&a,4)==0,27);
    char *args[]={(char *)self,"child",0}, *env[]={0};
    CHECK(posix_spawn(&pid,self,&a,0,args,env)==0,28);
    posix_spawn_file_actions_destroy(&a); close(channel[1]);
    CHECK(pid!=getpid(),29);
    CHECK(send_rights(channel[0],fd,ack[1])==4,30);
    close(fd); close(ack[1]);
    char bytes[2];
    CHECK(read(ack[0],bytes,2)==2 && !memcmp(bytes,"OK",2),31);
    CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0,32);
    CHECK(lseek(keep,0,SEEK_CUR)==4 && read(keep,bytes,2)==2 && !memcmp(bytes,"ef",2),33);
    close(channel[0]); close(ack[0]); close(keep);
    printf("[NATIVE-IPC %s PASS]\n",type==SOCK_STREAM ? "STREAM-RIGHTS" : "PACKET-RIGHTS");
    return 0;
}
static int edge_test(void) {
    int s[2]; union control c={0}; char data[4];
    CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,s)==0,41);
    struct iovec iov={data,sizeof data}; struct msghdr m={0};
    m.msg_iov=&iov; m.msg_iovlen=1;
    errno=0;
    CHECK(recvmsg(s[1],&m,MSG_DONTWAIT)==-1 && errno==EAGAIN,42);
    m.msg_control=c.bytes; m.msg_controllen=sizeof c;
    struct cmsghdr *h=CMSG_FIRSTHDR(&m); h->cmsg_len=3;
    errno=0;
    CHECK(sendmsg(s[0],&m,0)==-1 && errno==EINVAL,43);
    CHECK(send_rights(s[0],s[0],s[1])==4,44);
    m.msg_control=0; m.msg_controllen=0;
    CHECK(recvmsg(s[1],&m,0)==4 && (m.msg_flags&MSG_CTRUNC),45);
    close(s[0]); close(s[1]);
    puts("[NATIVE-IPC FLAGS-AND-BOUNDS PASS]");
    return 0;
}
static int shared_child(void) {
    char bytes[4]; union control c={0};
    struct iovec iov={bytes,4}; struct msghdr m={0};
    m.msg_iov=&iov; m.msg_iovlen=1;
    m.msg_control=c.bytes; m.msg_controllen=sizeof c;
    CHECK(recvmsg(3,&m,0)==4 && !m.msg_flags,61);
    int fds[2]; memcpy(fds,CMSG_DATA(CMSG_FIRSTHDR(&m)),sizeof fds);
    volatile unsigned *rw=mmap(0,8192,PROT_READ|PROT_WRITE,MAP_SHARED,fds[0],0);
    CHECK(rw!=MAP_FAILED && rw[0]==123 && rw[1024]==456,62);
    errno=0;
    CHECK(mmap(0,4096,PROT_WRITE,MAP_SHARED,fds[1],0)==MAP_FAILED && errno==EACCES,63);
    void *ro=mmap(0,4096,PROT_READ,MAP_SHARED,fds[1],4096);
    CHECK(ro!=MAP_FAILED && *(unsigned *)ro==456,64);
    errno=0;
    CHECK(mprotect(ro,4096,PROT_READ|PROT_WRITE)==-1 && errno==EACCES,65);
    void *upgrade=mmap(0,4096,PROT_READ,MAP_SHARED,fds[0],0);
    CHECK(upgrade!=MAP_FAILED && mprotect(upgrade,4096,PROT_READ|PROT_WRITE)==0,66);
    *(unsigned *)upgrade=789;
    CHECK(rw[0]==789,67);
    CHECK(munmap(upgrade,4096)==0,68);
    rw[1024]=987;
    close(fds[0]); close(fds[1]);
    CHECK(write(3,"M",1)==1 && read(3,bytes,1)==1,69);
    /* The sender has now closed its descriptors and unmapped its view. */
    CHECK(rw[0]==789 && rw[1024]==987,70);
    rw[0]=314;
    CHECK(mprotect((void *)rw,8192,PROT_NONE)==0,71);
    CHECK(mprotect((void *)rw,8192,PROT_READ)==0 && rw[0]==314,72);
    CHECK(munmap((void *)rw,8192)==0,73);
    /* Exit with an owned PROT_NONE mapping: world destruction must release it. */
    CHECK(mprotect(ro,4096,PROT_NONE)==0,74);
    close(3);
    return 0;
}
static int shared_test(const char *self) {
    int channel[2],status; pid_t pid; posix_spawn_file_actions_t a;
    const char *path="/native-shared";
    int fd=shm_open(path,O_CREAT|O_EXCL|O_RDWR,0600), ro;
    CHECK(fd>=0 && ftruncate(fd,8192)==0,81);
    CHECK(fcntl(fd,F_GETFD)==FD_CLOEXEC,102);
    errno=0;
    CHECK(shm_open(path,O_CREAT|O_EXCL|O_RDWR,0600)==-1 && errno==EEXIST,103);
    CHECK((ro=shm_open(path,O_RDONLY,0))>=0 && shm_unlink(path)==0,82);
    errno=0;
    CHECK(shm_open(path,O_RDWR,0)==-1 && errno==ENOENT,104);
    errno=0;
    CHECK(shm_unlink(path)==-1 && errno==ENOENT,105);
    const char *bad[]={"", "relative", "/", "/.", "/..", "/x/y"};
    for(unsigned i=0;i<sizeof bad/sizeof *bad;++i) {
        errno=0;
        CHECK(shm_open(bad[i],O_CREAT|O_RDWR,0600)==-1 && errno==EINVAL,106);
        errno=0;
        CHECK(shm_unlink(bad[i])==-1 && errno==EINVAL,107);
    }
    char longname[258]; memset(longname,'x',sizeof longname);
    longname[0]='/'; longname[257]=0; errno=0;
    CHECK(shm_open(longname,O_CREAT|O_RDWR,0600)==-1 && errno==ENAMETOOLONG,108);
    errno=0;
    CHECK(shm_open(path,O_CREAT|O_WRONLY,0600)==-1 && errno==EINVAL,109);
    puts("[NATIVE-IPC SHM-NAMES PASS]");
    volatile unsigned *view=mmap(0,8192,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    CHECK(view!=MAP_FAILED,83);
    view[0]=123; view[1024]=456;
    unsigned value=0;
    CHECK(pread(fd,&value,4,0)==4 && value==123,84);
    value=321;
    CHECK(pwrite(fd,&value,4,4)==4 && view[1]==321,85);
    errno=0;
    CHECK(mmap(0,4096,PROT_READ,MAP_SHARED,fd,8192)==MAP_FAILED && errno==EINVAL,86);
    errno=0;
    CHECK(mmap(0,4096,PROT_READ,MAP_SHARED,fd,1)==MAP_FAILED && errno==EINVAL,87);
    errno=0;
    CHECK(mmap(0,64*1024*1024+4096,PROT_READ,MAP_SHARED,fd,0)==MAP_FAILED && errno==EINVAL,101);
    errno=0;
    CHECK(ftruncate(fd,4096)==-1 && errno==EBUSY,88);
    CHECK(socketpair(AF_UNIX,SOCK_SEQPACKET,0,channel)==0,89);
    CHECK(posix_spawn_file_actions_init(&a)==0,90);
    CHECK(posix_spawn_file_actions_adddup2(&a,channel[1],3)==0,91);
    CHECK(posix_spawn_file_actions_addclosefrom_np(&a,4)==0,92);
    char *args[]={(char *)self,"shared-child",0}, *env[]={0};
    CHECK(posix_spawn(&pid,self,&a,0,args,env)==0,93);
    posix_spawn_file_actions_destroy(&a); close(channel[1]);
    CHECK(send_rights(channel[0],fd,ro)==4,94);
    char byte;
    CHECK(read(channel[0],&byte,1)==1 && byte=='M',95);
    CHECK(view[0]==789 && view[1024]==987,96);
    CHECK(pread(fd,&value,4,4096)==4 && value==987,97);
    close(fd); close(ro); CHECK(munmap((void *)view,8192)==0,98);
    CHECK(write(channel[0],"G",1)==1,99);
    CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0,100);
    close(channel[0]);
    puts("[NATIVE-IPC SHARED-PAGES PASS]");
    return 0;
}
int main(int argc, char **argv) {
    if (argc>1 && !strcmp(argv[1],"shared-child")) return shared_child();
    if (argc>1 && !strcmp(argv[1],"child")) return child();
    if (argc>1 && !strcmp(argv[1],"hold")) { char c; CHECK(read(0,&c,1)==1,50); }
    int r=pair_test(argv[0],SOCK_STREAM); if(r) return r;
    r=pair_test(argv[0],SOCK_SEQPACKET); if(r) return r;
    r=edge_test(); if(r) return r;
    return shared_test(argv[0]);
}
