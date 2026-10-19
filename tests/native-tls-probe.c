/* Clang emits real local-exec TLS relocations, including over-aligned TBSS.
 * The runtime is the same Low libsa object used by SBCL and target builds. */
#include <pthread.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>

#ifndef TLS_ALIGNMENT
#define TLS_ALIGNMENT 64
#endif
static __thread volatile int initial = 37;
static __thread volatile unsigned char zero[64] __attribute__((aligned(TLS_ALIGNMENT)));
static int ready;
static unsigned long addresses[3], errors[3];

static void *worker(void *arg) {
    unsigned long id = (unsigned long)arg;
    int i;
    if (initial != 37 || ((unsigned long)zero % TLS_ALIGNMENT)) return (void *)1;
    for (i = 0; i < 64; ++i) if (zero[i]) return (void *)2;
    initial = 100 + id;
    zero[0] = id;
    addresses[id] = (unsigned long)&initial;
    errors[id] = (unsigned long)&errno;
    close(4095);
    if (errno != EBADF) return (void *)3;
    /* Synchronize without libc calls: successful pthread calls may alter
     * errno, which is distinct from another thread overwriting its slot. */
    __sync_add_and_fetch(&ready, 1);
    while (__sync_val_compare_and_swap(&ready, 0, 0) < 2)
        __asm__ volatile("pause");
    if (initial != 100 + id || zero[0] != id || errno != EBADF)
        return (void *)4;
    return 0;
}
int main(void) {
    pthread_t a, b;
    void *ra, *rb;
    if (initial != 37 || zero[0] || ((unsigned long)zero % TLS_ALIGNMENT)) return 1;
    initial = 99; zero[0] = 9; errno = 123;
    addresses[0] = (unsigned long)&initial;
    errors[0] = (unsigned long)&errno;
    if (pthread_create(&a, 0, worker, (void *)1) ||
        pthread_create(&b, 0, worker, (void *)2)) return 2;
    while (__sync_val_compare_and_swap(&ready, 0, 0) < 2)
        __asm__ volatile("pause");
    if (errno != 123) return 7;
    if (pthread_join(a, &ra) || pthread_join(b, &rb) || ra || rb) return 3;
    if (initial != 99 || zero[0] != 9) return 4;
    if (addresses[0] == addresses[1] || addresses[0] == addresses[2] ||
        addresses[1] == addresses[2]) return 5;
    if (errors[0] == errors[1] || errors[0] == errors[2] ||
        errors[1] == errors[2]) return 6;
    return 0;
}
