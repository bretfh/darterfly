#include <time.h>
#include <sys/time.h>
#include <sys/select.h>
#include <errno.h>
#include <string.h>
#include "libsa.h"

typedef struct { uint64_t tsc_hz, tsc_base, epoch_base; } commpage_time;

static commpage_time *commpage;

static commpage_time *page(void) {
  if (!commpage) commpage = (commpage_time *)__machdep(MACHDEP_commpage, 0);
  return commpage;
}

static uint64_t rdtsc(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
}

static uint64_t nanos_since_boot(void) {
  commpage_time *c = page();
  uint64_t t = rdtsc() - c->tsc_base;
  return t / c->tsc_hz * 1000000000u + t % c->tsc_hz * 1000000000u / c->tsc_hz;
}

int clock_gettime(clockid_t id, struct timespec *ts) {
  uint64_t ns = nanos_since_boot();
  if (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE) ns += page()->epoch_base * 1000000000ull;
  ts->tv_sec = (time_t)(ns / 1000000000u);
  ts->tv_nsec = (long)(ns % 1000000000u);
  return 0;
}

int clock_getres(clockid_t id, struct timespec *ts) {
  (void)id;
  ts->tv_sec = 0;
  ts->tv_nsec = 1;
  return 0;
}

int gettimeofday(struct timeval *tv, void *tz) {
  (void)tz;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  tv->tv_sec = ts.tv_sec;
  tv->tv_usec = ts.tv_nsec / 1000;
  return 0;
}

time_t time(time_t *t) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  if (t) *t = ts.tv_sec;
  return ts.tv_sec;
}

clock_t clock(void) { return (clock_t)(nanos_since_boot() / 1000); }

int nanosleep(const struct timespec *req, struct timespec *rem) {
  uint64_t end = nanos_since_boot() + (uint64_t)req->tv_sec * 1000000000u + (uint64_t)req->tv_nsec;
  while (nanos_since_boot() < end) __asm__ volatile("pause");
  if (rem) rem->tv_sec = rem->tv_nsec = 0;
  return 0;
}

unsigned sleep(unsigned s) {
  struct timespec ts = {s, 0};
  nanosleep(&ts, 0);
  return 0;
}

int usleep(useconds_t us) {
  struct timespec ts = {us / 1000000, (long)(us % 1000000) * 1000};
  return nanosleep(&ts, 0);
}

int setitimer(int which, const struct itimerval *v, struct itimerval *old) {
  (void)which; (void)v;
  if (old) memset(old, 0, sizeof *old);
  return 0;
}

int getitimer(int which, struct itimerval *v) { (void)which; memset(v, 0, sizeof *v); return 0; }

long timezone;
int daylight;
char *tzname[2] = {"UTC", "UTC"};
void tzset(void) {}

static int leap(long y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }
static const int mdays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

struct tm *gmtime_r(const time_t *t, struct tm *tm) {
  long s = *t, days = s / 86400, rem = s % 86400;
  if (rem < 0) rem += 86400, days--;
  tm->tm_hour = (int)(rem / 3600);
  tm->tm_min = (int)(rem % 3600 / 60);
  tm->tm_sec = (int)(rem % 60);
  tm->tm_wday = (int)((days + 4) % 7);
  if (tm->tm_wday < 0) tm->tm_wday += 7;
  long y = 1970;
  for (;;) {
    long n = leap(y) ? 366 : 365;
    if (days < 0) { y--; days += leap(y) ? 366 : 365; continue; }
    if (days < n) break;
    days -= n;
    y++;
  }
  tm->tm_year = (int)(y - 1900);
  tm->tm_yday = (int)days;
  int m = 0;
  for (; m < 12; m++) {
    int n = mdays[m] + (m == 1 && leap(y));
    if (days < n) break;
    days -= n;
  }
  tm->tm_mon = m;
  tm->tm_mday = (int)days + 1;
  tm->tm_isdst = 0;
  tm->tm_gmtoff = 0;
  tm->tm_zone = "UTC";
  return tm;
}

struct tm *localtime_r(const time_t *t, struct tm *tm) { return gmtime_r(t, tm); }
static struct tm shared_tm;
struct tm *gmtime(const time_t *t) { return gmtime_r(t, &shared_tm); }
struct tm *localtime(const time_t *t) { return gmtime_r(t, &shared_tm); }

time_t mktime(struct tm *tm) {
  long y = tm->tm_year + 1900, days = 0;
  for (long i = 1970; i < y; i++) days += leap(i) ? 366 : 365;
  for (int m = 0; m < tm->tm_mon; m++) days += mdays[m] + (m == 1 && leap(y));
  days += tm->tm_mday - 1;
  return days * 86400 + tm->tm_hour * 3600 + tm->tm_min * 60 + tm->tm_sec;
}

size_t strftime(char *out, size_t n, const char *f, const struct tm *tm) {
  extern int snprintf(char *, size_t, const char *, ...);
  int k = snprintf(out, n, "%04d-%02d-%02d %02d:%02d:%02d", tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
                   tm->tm_hour, tm->tm_min, tm->tm_sec);
  (void)f;
  return k < 0 || (size_t)k >= n ? 0 : (size_t)k;
}

int select(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *t) {
  (void)n; (void)r; (void)w; (void)e; (void)t;
  errno = ENOSYS;
  return -1;
}
