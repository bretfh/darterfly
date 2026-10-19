#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <time.h>
struct timeval { time_t tv_sec; suseconds_t tv_usec; };
struct timezone { int tz_minuteswest, tz_dsttime; };
struct itimerval { struct timeval it_interval, it_value; };
#define timercmp(a, b, op) \
  ((a)->tv_sec == (b)->tv_sec ? (a)->tv_usec op (b)->tv_usec \
                            : (a)->tv_sec op (b)->tv_sec)
#define timerclear(a) ((a)->tv_sec = (a)->tv_usec = 0)
#define timerisset(a) ((a)->tv_sec || (a)->tv_usec)
#define ITIMER_REAL 0
#define ITIMER_VIRTUAL 1
#define ITIMER_PROF 2
int gettimeofday(struct timeval *, void *);
int setitimer(int, const struct itimerval *, struct itimerval *);
int getitimer(int, struct itimerval *);
int utimes(const char *, const struct timeval[2]);

#ifdef __cplusplus
}
#endif
