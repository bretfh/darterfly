#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
static void check(const char *s, bool ok) {
    printf("[DL %s %s]\n", s, ok ? "PASS" : "FAIL"); fflush(stdout);
    if (!ok) { const char *e = dlerror(); printf("loader: %s\n",e?e:"none"); exit(1); }
}
static bool rejected(const char *path, const char *reason) {
    void *h = dlopen(path, RTLD_NOW);
    const char *e = dlerror();
    if (h || !e || !strstr(e, reason)) {
        printf("reject %s: %s (wanted %s)\n", path, e ? e : "none", reason);
        return false;
    }
    return !dlerror();
}
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int stage, ready;
static int *(*tls)();
static void *(*zero)();
static int *main_tls;
static void *worker(void *) {
    pthread_mutex_lock(&lock);
    ++ready; pthread_cond_signal(&cond);
    while (!stage) pthread_cond_wait(&cond, &lock);
    pthread_mutex_unlock(&lock);
    bool errors = !dlerror() && rejected("/tmp/libbad.so","missing_engine_service");
    int *p = tls();
    unsigned char *z = (unsigned char *)zero();
    bool ok = errors && p != main_tls && *p == 31 && z[0] == 0 &&
              ((uintptr_t)z % 256) == 0;
    *p = 73; z[0] = 5;
    return (void *)(uintptr_t)(ok && *p == 73 && z[0] == 5);
}
static int callback(int n) { return n * 2; }
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "hold")) { char c; read(0, &c, 1); }
    if (argc > 1 && (!strcmp(argv[1], "text") || !strcmp(argv[1], "relro"))) {
        void *h = dlopen("/tmp/libroot.so", RTLD_NOW);
        if (!h) return 2;
        void *p = dlsym(h, "root_value");
        if (!strcmp(argv[1], "relro"))
            p = (void *)((const void *(*)())dlsym(h,"root_relro_address"))();
        *(volatile unsigned char *)p = 0;
        return 3;
    }
    pthread_t old_thread;
    check("OLD-THREAD-CREATE", !pthread_create(&old_thread,0,worker,0));
    pthread_mutex_lock(&lock);
    while (!ready) pthread_cond_wait(&cond, &lock);
    pthread_mutex_unlock(&lock);
    for (int i=0;i<70;++i) {
        if (!rejected("/tmp/libbad.so", "missing_engine_service")) return 10;
        if (dlerror()) return 11;
    }
    check("ROLLBACK", true);
    check("TRUNCATED", rejected("/tmp/truncated.so","expected bounded"));
    check("BAD-SYMBOL", rejected("/tmp/bad-symbol.so","out-of-bounds symbol"));
    check("BAD-RELOCATION", rejected("/tmp/bad-relocation.so","nonwritable target"));
    check("BAD-CONSTRUCTOR", rejected("/tmp/bad-constructor.so","outside executable segment"));
    check("STATIC-TLS-REJECTED", rejected("/tmp/static-tls.so","unsupported relocation"));
    check("WX-REJECTED", rejected("/tmp/wx.so","W+X load segment"));
    check("MISSING-DEPENDENCY", rejected("/tmp/missing/libroot.so","path unavailable"));
    check("NOLOAD-ABSENT", !dlopen("/tmp/libroot.so", RTLD_NOW|RTLD_NOLOAD));
    const char *absent = dlerror();
    check("NOLOAD-ERROR", absent && strstr(absent, "not loaded") && !dlerror());
    void *h = dlopen("/tmp/libroot.so", RTLD_NOW);
    check("LOAD", h);
    void *resident = dlopen("/tmp/libroot.so", RTLD_NOW|RTLD_NOLOAD);
    check("NOLOAD-RESIDENT", resident == h && !dlclose(resident));
    int (*value)() = (int(*)())dlsym(h,"root_value");
    check("CONSTRUCTORS", value && value() == 19);
    check("CONSTRUCTOR-THREAD", *(int*)dlsym(h,"root_tls_destroyed") == 1);
    check("DEPENDENCY-SCOPE", ((int(*)())dlsym(h,"leaf_value"))() == 17);
    check("LOCAL-SCOPE", !dlsym(RTLD_DEFAULT,"root_value") && dlerror());
    void *(*allocate)(unsigned long) = (void*(*)(unsigned long))dlsym(h,"root_malloc");
    void (*release)(void*) = (void(*)(void*))dlsym(h,"root_free");
    void *p = allocate(81); check("SHARED-ALLOCATOR", p); free(p);
    p = malloc(39); release(p);
    ((void(*)(int))dlsym(h,"root_errno"))(123);
    check("SHARED-ERRNO", errno == 123);
    check("CALLBACK", ((int(*)(int(*)(int),int))dlsym(h,"root_callback"))(callback,12) == 41);
    tls = (int*(*)())dlsym(h,"root_tls");
    zero = (void*(*)())dlsym(h,"root_zero");
    main_tls = tls();
    check("TLS-MAIN", main_tls && *main_tls == 31 &&
          dlsym(h,"dynamic_value") == main_tls);
    *main_tls = 99;
    (void)dlsym(h, "missing_main_thread_symbol");
    check("CLOSE-RESIDENT", !dlclose(h));
    pthread_mutex_lock(&lock); stage=1; pthread_cond_broadcast(&cond); pthread_mutex_unlock(&lock);
    void *result = 0; pthread_join(old_thread,&result);
    check("TLS-OLD-THREAD", (uintptr_t)result == 1 && *main_tls == 99);
    pthread_t new_thread;
    check("NEW-THREAD-CREATE", !pthread_create(&new_thread,0,worker,0));
    pthread_join(new_thread,&result);
    check("TLS-NEW-THREAD", (uintptr_t)result == 1 && *main_tls == 99);
    const char *main_error = dlerror();
    check("THREAD-ERRORS", main_error && strstr(main_error,"dlsym:"));
    void *again = dlopen("/tmp/libroot.so", RTLD_NOW|RTLD_NOLOAD|RTLD_GLOBAL);
    check("REOPEN-GLOBAL", again == h && dlsym(RTLD_DEFAULT,"root_value") == (void*)value && value()==19 &&
          *(int*)dlsym(again,"root_constructions") == 1);
    check("TLS-DESTRUCTORS", *(int*)dlsym(h,"root_tls_destroyed") == 3);
    Dl_info info;
    check("ADDRESS", dladdr((void*)value,&info) && strstr(info.dli_fname,"libroot.so"));
    check("RUNTIME", dlsym(dlopen(0,RTLD_NOW),"malloc") == (void*)malloc);
    check("CLOSE", !dlclose(again) && dlclose(again) == -1 && dlerror());
    return 0;
}
