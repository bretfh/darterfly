#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int sched_yield(void);
int sched_getcpu(void);

#ifdef __cplusplus
}
#endif
