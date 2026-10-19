#include <arpa/inet.h>
#include <fnmatch.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <resolv.h>
extern int darter_inet_pton(int,const char *,void *);
extern const char *darter_inet_ntop(int,const void *,char *,socklen_t);
extern int darter_fnmatch(const char *,const char *,int);
extern int darter_dn_expand(const unsigned char *,const unsigned char *,const unsigned char *,char *,int);
static uint64_t seed=0x12345678;
static unsigned next(void){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return (unsigned)seed;}
int main(void){
    char text[80],result[80];unsigned char bytes[16],parsed[16];
    for(int i=0;i<10000;i++){
        for(unsigned k=0;k<16;k++)bytes[k]=(unsigned char)next();
        if(!inet_ntop(AF_INET6,bytes,text,sizeof text) ||
           darter_inet_pton(AF_INET6,text,parsed)!=1 || memcmp(bytes,parsed,16) ||
           !darter_inet_ntop(AF_INET6,bytes,result,sizeof result) ||
           inet_pton(AF_INET6,result,parsed)!=1 || memcmp(bytes,parsed,16))return 1;
    }
    const char *invalid[]={"",":","1:","1::2::3","12345::","1:2:3:4:5:6:7:8:9",
        "::ffff:256.0.0.1","::ffff:01.0.0.1","[::1]","::1%eth0","::g"};
    for(unsigned i=0;i<sizeof invalid/sizeof *invalid;i++)
        if(darter_inet_pton(AF_INET6,invalid[i],parsed)!=0)return 2;
    const char *patterns[]={"*","?","a*b*c","*.c","[a-z]*","[!a-c]?",
        "[[:alpha:]][[:digit:]]*","*/*","a\\*b","[]a]","[","[a-]","[z-a]",".*","*.*"};
    const char alphabet[]="abcxyzABC012./*\\";
    for(int i=0;i<50000;i++){
        unsigned n=next()%14;
        for(unsigned k=0;k<n;k++)text[k]=alphabet[next()%(sizeof alphabet-1)];
        text[n]=0;
        unsigned flags=next()%32;
        const char *pattern=patterns[next()%(sizeof patterns/sizeof *patterns)];
        int a=darter_fnmatch(pattern,text,flags),b=fnmatch(pattern,text,flags);
        if((a==0)!=(b==0)){printf("GLOB mismatch [%s] [%s] flags=%u got=%d want=%d\n",pattern,text,flags,a,b);return 3;}
    }
    unsigned char packet[]={3,'w','w','w',7,'e','x','a','m','p','l','e',3,'c','o','m',0,0xc0,0};
    for(int size=1;size<40;size++){
        int a=darter_dn_expand(packet,packet+sizeof packet,packet+17,text,size);
        int b=dn_expand(packet,packet+sizeof packet,packet+17,result,size);
        if(a!=b || (a>=0 && strcmp(text,result)))return 4;
    }
    puts("NETWORK PRIMITIVES PASS 10000 address roundtrips, 50000 globs, DNS bounds");
    return 0;
}
