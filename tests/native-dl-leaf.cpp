#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
extern "C" {
int leaf_ready;
__attribute__((constructor)) static void initialize() { leaf_ready = 17; }
__attribute__((destructor)) static void finalize() {
    int fd = open("/tmp/dl-finalized", O_WRONLY|O_CREAT|O_APPEND, 0600);
    write(fd, "L", 1); close(fd);
}
int leaf_value() { return leaf_ready; }
void *leaf_allocate(unsigned long n) { return malloc(n); }
}
