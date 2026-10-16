#include <time.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/times.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "libsa.h"

typedef struct { uint64_t tsc_hz, tsc_base, epoch_base; } commpage_time;

static commpage_time *commpage;

static commpage_time *page(void) {
  if (!commpage) commpage = (commpage_time *)__machdep(MACHDEP_commpage, 0, 0);
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
  if (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE || id == CLOCK_REALTIME_ALARM || id == CLOCK_TAI) ns += page()->epoch_base * 1000000000ull;
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

clock_t times(struct tms *t) {
  if (t) *t = (struct tms){0, 0, 0, 0};
  return (clock_t)(nanos_since_boot() / 10000000);
}

int nanosleep(const struct timespec *req, struct timespec *rem) {
  uint64_t end = nanos_since_boot() + (uint64_t)req->tv_sec * 1000000000u + (uint64_t)req->tv_nsec;
  long r = __syscall(SYS___semwait_signal, req->tv_sec, req->tv_nsec, 0, 0, 0, 0);
  if (rem) {
    uint64_t now = nanos_since_boot(), left = now < end ? end - now : 0;
    rem->tv_sec = (time_t)(left / 1000000000u);
    rem->tv_nsec = (long)(left % 1000000000u);
  }
  return r < 0 ? -1 : 0;
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
  return (int)__syscall(SYS_setitimer, which, (long)v, (long)old, 0, 0, 0);
}

int getitimer(int which, struct itimerval *v) { return (int)__syscall(SYS_getitimer, which, (long)v, 0, 0, 0, 0); }

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

#define ZONE_PATH "/etc/localtime"
#define ZONE_TYPES 256

struct zone_type { long utoff; int isdst; const char *name; };
struct zone_rule { int kind, month, week, day; long time; };

static struct {
  int loaded, count, types;
  long long *at;
  unsigned char *index;
  struct zone_type type[ZONE_TYPES];
  char *names;
  int posix;
  struct zone_type std, dst;
  int has_dst;
  struct zone_rule start, end;
  char std_name[16], dst_name[16];
} zone;
static char zone_lock;

static long long be(const unsigned char *p, int n) {
  unsigned long long v = 0;
  for (int i = 0; i < n; i++) v = v << 8 | p[i];
  if (n == 4) return (int32_t)v;
  return (long long)v;
}

static const char *posix_name(const char *s, char *out) {
  int n = 0;
  if (*s == '<') {
    for (s++; *s && *s != '>'; s++) if (n < 15) out[n++] = *s;
    if (*s) s++;
  } else {
    for (; (*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z'); s++) if (n < 15) out[n++] = *s;
  }
  out[n] = 0;
  return n ? s : 0;
}

static const char *posix_number(const char *s, long *v) {
  long n = 0;
  if (*s < '0' || *s > '9') return 0;
  while (*s >= '0' && *s <= '9') n = n * 10 + *s++ - '0';
  *v = n;
  return s;
}

static const char *posix_time(const char *s, long *v) {
  int sign = 1;
  long h = 0, m = 0, sec = 0;
  if (*s == '+' || *s == '-') sign = *s++ == '-' ? -1 : 1;
  if (!(s = posix_number(s, &h))) return 0;
  if (*s == ':' && !(s = posix_number(s + 1, &m))) return 0;
  if (*s == ':' && !(s = posix_number(s + 1, &sec))) return 0;
  *v = sign * (h * 3600 + m * 60 + sec);
  return s;
}

static const char *posix_rule(const char *s, struct zone_rule *r) {
  long a, b, c;
  if (*s == 'M') {
    if (!(s = posix_number(s + 1, &a)) || *s != '.' || !(s = posix_number(s + 1, &b)) || *s != '.' ||
        !(s = posix_number(s + 1, &c)))
      return 0;
    r->kind = 'M', r->month = (int)a, r->week = (int)b, r->day = (int)c;
  } else if (*s == 'J') {
    if (!(s = posix_number(s + 1, &a))) return 0;
    r->kind = 'J', r->day = (int)a;
  } else {
    if (!(s = posix_number(s, &a))) return 0;
    r->kind = 'D', r->day = (int)a;
  }
  r->time = 7200;
  if (*s == '/' && !(s = posix_time(s + 1, &r->time))) return 0;
  return s;
}

static void parse_posix(const char *s) {
  long off;
  if (!(s = posix_name(s, zone.std_name)) || !(s = posix_time(s, &off))) return;
  zone.std = (struct zone_type){-off, 0, zone.std_name};
  zone.posix = 1;
  if (!*s) return;
  if (!(s = posix_name(s, zone.dst_name))) return;
  zone.dst = (struct zone_type){zone.std.utoff + 3600, 1, zone.dst_name};
  if (*s && *s != ',') {
    if (!(s = posix_time(s, &off))) return;
    zone.dst.utoff = -off;
  }
  zone.start = (struct zone_rule){'M', 3, 2, 0, 7200};
  zone.end = (struct zone_rule){'M', 11, 1, 0, 7200};
  if (*s == ',' && (!(s = posix_rule(s + 1, &zone.start)) || *s != ',' || !(s = posix_rule(s + 1, &zone.end)))) return;
  zone.has_dst = 1;
}

static long days_from_civil(long y, int m, int d) {
  y -= m <= 2;
  long era = (y >= 0 ? y : y - 399) / 400;
  long yoe = y - era * 400;
  long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static long rule_seconds(long y, struct zone_rule *r) {
  long day;
  if (r->kind == 'J') {
    day = days_from_civil(y, 1, 1) + r->day - 1;
    if (leap(y) && r->day >= 60) day++;
  } else if (r->kind == 'D') {
    day = days_from_civil(y, 1, 1) + r->day;
  } else {
    long first = days_from_civil(y, r->month, 1);
    int wday = (int)(((first + 4) % 7 + 7) % 7);
    int mday = 1 + (r->day - wday + 7) % 7 + (r->week - 1) * 7;
    int length = mdays[r->month - 1] + (r->month == 2 && leap(y));
    while (mday > length) mday -= 7;
    day = first + mday - 1;
  }
  return day * 86400 + r->time;
}

static struct zone_type *posix_type(long long t) {
  if (!zone.has_dst) return &zone.std;
  struct tm tm;
  time_t local = (time_t)(t + zone.std.utoff);
  gmtime_r(&local, &tm);
  long y = tm.tm_year + 1900;
  long long start = rule_seconds(y, &zone.start) - zone.std.utoff;
  long long end = rule_seconds(y, &zone.end) - zone.dst.utoff;
  int in = start < end ? t >= start && t < end : !(t >= end && t < start);
  return in ? &zone.dst : &zone.std;
}

static void load_zone(void) {
  int fd = open(ZONE_PATH, O_RDONLY);
  if (fd < 0) return;
  struct stat st;
  unsigned char *b = 0;
  if (fstat(fd, &st) == 0 && st.st_size > 44 && (b = malloc((size_t)st.st_size + 1))) {
    long got = 0, n;
    while (got < st.st_size && (n = read(fd, b + got, (size_t)(st.st_size - got))) > 0) got += n;
    if (got != st.st_size) free(b), b = 0;
  }
  close(fd);
  if (!b) return;
  long size = st.st_size, p = 0;
  b[size] = 0;
  if (memcmp(b, "TZif", 4)) return;
  int width = 4;
  for (int pass = 0; pass < 2; pass++) {
    if (p + 44 > size) return;
    long isut = be(b + p + 20, 4), isstd = be(b + p + 24, 4), leaps = be(b + p + 28, 4);
    long times = be(b + p + 32, 4), types = be(b + p + 36, 4), chars = be(b + p + 40, 4);
    long body = times * width + times + types * 6 + chars + leaps * (width + 4) + isstd + isut;
    if (types < 1 || types > ZONE_TYPES || p + 44 + body > size) return;
    if (pass == 0 && b[4] >= '2') {
      p += 44 + body;
      width = 8;
      continue;
    }
    unsigned char *q = b + p + 44;
    zone.count = (int)times;
    zone.types = (int)types;
    zone.at = malloc(sizeof(long long) * (size_t)(times ? times : 1));
    zone.index = malloc((size_t)(times ? times : 1));
    zone.names = malloc((size_t)chars + 1);
    if (!zone.at || !zone.index || !zone.names) return;
    for (long i = 0; i < times; i++) zone.at[i] = be(q + i * width, width);
    q += times * width;
    for (long i = 0; i < times; i++) zone.index[i] = q[i] < types ? q[i] : 0;
    q += times;
    unsigned char *names = q + types * 6;
    memcpy(zone.names, names, (size_t)chars);
    zone.names[chars] = 0;
    for (long i = 0; i < types; i++) {
      int at = q[i * 6 + 5];
      zone.type[i] = (struct zone_type){(long)be(q + i * 6, 4), q[i * 6 + 4], zone.names + (at < chars ? at : chars)};
    }
    p += 44 + body;
    if (width == 8 && p < size && b[p] == '\n') {
      char *end = strchr((char *)b + p + 1, '\n');
      if (end) *end = 0, parse_posix((char *)b + p + 1);
    }
    break;
  }
  free(b);
}

static struct zone_type *zone_type(long long t) {
  if (!zone.loaded) {
    while (__atomic_test_and_set(&zone_lock, __ATOMIC_ACQUIRE)) sched_yield();
    if (!zone.loaded) load_zone(), zone.loaded = 1;
    __atomic_clear(&zone_lock, __ATOMIC_RELEASE);
  }
  if (zone.types == 0 && !zone.posix) return 0;
  if (zone.count && t >= zone.at[zone.count - 1] && zone.posix) return posix_type(t);
  if (zone.count == 0) return zone.posix ? posix_type(t) : &zone.type[0];
  if (t < zone.at[0]) {
    for (int i = 0; i < zone.types; i++)
      if (!zone.type[i].isdst) return &zone.type[i];
    return &zone.type[0];
  }
  int lo = 0, hi = zone.count - 1;
  while (lo < hi) {
    int mid = (lo + hi + 1) / 2;
    if (zone.at[mid] <= t) lo = mid; else hi = mid - 1;
  }
  return &zone.type[zone.index[lo]];
}

struct tm *localtime_r(const time_t *t, struct tm *tm) {
  struct zone_type *z = zone_type(*t);
  if (!z) return gmtime_r(t, tm);
  time_t local = *t + z->utoff;
  gmtime_r(&local, tm);
  tm->tm_isdst = z->isdst;
  tm->tm_gmtoff = z->utoff;
  tm->tm_zone = z->name;
  return tm;
}

static struct tm shared_tm;
struct tm *gmtime(const time_t *t) { return gmtime_r(t, &shared_tm); }
struct tm *localtime(const time_t *t) { return localtime_r(t, &shared_tm); }

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
