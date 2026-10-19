/* Keep upstream process entry points intact; register the static GIO backend. */
#include "config.h"
#include <cstdio>
#include <unistd.h>
#if defined(DARTER_NETWORK_PROCESS)
#include "NetworkProcessMain.h"
#else
#include "WebProcessMain.h"
#endif
extern "C" void darter_register_openssl(void);
int main(int argc,char **argv) {
    fprintf(stderr,"ENGINE process-entry %s pid=%d argc=%d\n",argv[0],getpid(),argc);
    darter_register_openssl();
#if defined(DARTER_NETWORK_PROCESS)
    return WebKit::NetworkProcessMain(argc,argv);
#else
    return WebKit::WebProcessMain(argc,argv);
#endif
}
