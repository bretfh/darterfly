#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
extern "C" {
int leaf_value();
void *leaf_allocate(unsigned long);
__attribute__((visibility("hidden"))) void *__dso_handle = &__dso_handle;
int root_ready;
int root_constructions;
int root_tls_destroyed;
struct ThreadGuard { ~ThreadGuard() { ++root_tls_destroyed; } };
thread_local ThreadGuard guard;
struct GlobalGuard {
    ~GlobalGuard() {
        int fd = open("/tmp/dl-finalized", O_WRONLY|O_CREAT|O_APPEND, 0600);
        write(fd, root_tls_destroyed == 4 ? "C" : "F", 1); close(fd);
    }
};
GlobalGuard global_guard;
thread_local int dynamic_value = 31;
alignas(256) thread_local unsigned char dynamic_zero[256];
int *root_tls();
static void *constructor_worker(void *) {
    int *value = root_tls();
    return (void *)(unsigned long)(*value == 31);
}
__attribute__((constructor)) static void initialize() {
    ++root_constructions;
    pthread_t thread;
    void *result = 0;
    if (pthread_create(&thread, 0, constructor_worker, 0)) return;
    pthread_join(thread, &result);
    if (result == (void *)1) root_ready = leaf_value() + 2;
}
__attribute__((destructor)) static void finalize() {
    int fd = open("/tmp/dl-finalized", O_WRONLY|O_CREAT|O_APPEND, 0600);
    write(fd, "R", 1); close(fd);
}
int root_value() { return root_ready; }
int *root_tls() { (void)&guard; return &dynamic_value; }
void *root_zero() { return dynamic_zero; }
void *root_malloc(unsigned long n) { return leaf_allocate(n); }
void root_free(void *p) { free(p); }
void root_errno(int n) { errno = n; }
int root_callback(int (*f)(int), int n) { return f(n) + leaf_value(); }
const void * const root_relro = (const void *)&root_value;
const void *root_relro_address() { return &root_relro; }
}
