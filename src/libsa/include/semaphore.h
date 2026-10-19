#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <time.h>
typedef struct { volatile unsigned count; } sem_t;
int sem_init(sem_t *, int, unsigned);
int sem_destroy(sem_t *);
int sem_wait(sem_t *);
int sem_trywait(sem_t *);
int sem_timedwait(sem_t *, const struct timespec *);
int sem_post(sem_t *);
int sem_getvalue(sem_t *, int *);

#ifdef __cplusplus
}
#endif
