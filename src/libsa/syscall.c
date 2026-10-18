#include <errno.h>

static __thread int errno_value;
int *__errno_location(void) { return &errno_value; }
