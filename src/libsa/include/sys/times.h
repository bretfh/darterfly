#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/types.h>
struct tms { clock_t tms_utime, tms_stime, tms_cutime, tms_cstime; };
clock_t times(struct tms *);

#ifdef __cplusplus
}
#endif
