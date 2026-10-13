#include <math.h>

#define X87_1(name, insn)                                       \
  double name(double x) {                                       \
    long double r;                                              \
    __asm__(insn : "=t"(r) : "0"((long double)x));              \
    return (double)r;                                           \
  }

X87_1(sqrt_x87, "fsqrt")
X87_1(sin_x87, "fsin")
X87_1(cos_x87, "fcos")

double sqrt(double x) { return __builtin_sqrt(x); }
float sqrtf(float x) { return __builtin_sqrtf(x); }
double fabs(double x) { return __builtin_fabs(x); }
float fabsf(float x) { return __builtin_fabsf(x); }
double copysign(double a, double b) { return __builtin_copysign(a, b); }

static double round_mode(double x, unsigned short mode) {
  long double r;
  unsigned short cw, ncw;
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  ncw = (cw & ~0x0c00) | mode;
  __asm__ volatile("fldcw %0" ::"m"(ncw));
  __asm__ volatile("frndint" : "=t"(r) : "0"((long double)x));
  __asm__ volatile("fldcw %0" ::"m"(cw));
  return (double)r;
}

double floor(double x) { return round_mode(x, 0x0400); }
double ceil(double x) { return round_mode(x, 0x0800); }
double trunc(double x) { return round_mode(x, 0x0c00); }
double rint(double x) { return round_mode(x, 0x0000); }
double round(double x) { return x < 0 ? -floor(-x + 0.5) : floor(x + 0.5); }
long lrint(double x) { return (long)rint(x); }
float floorf(float x) { return (float)floor(x); }
float ceilf(float x) { return (float)ceil(x); }
float truncf(float x) { return (float)trunc(x); }
long double truncl(long double x) { return trunc((double)x); }

double sin(double x) { return sin_x87(x); }
double cos(double x) { return cos_x87(x); }

double tan(double x) {
  long double r, one;
  __asm__("fptan" : "=t"(one), "=u"(r) : "0"((long double)x));
  return (double)r;
}

double atan2(double y, double x) {
  long double r;
  __asm__("fpatan" : "=t"(r) : "0"((long double)x), "u"((long double)y) : "st(1)");
  return (double)r;
}

double atan(double x) { return atan2(x, 1.0); }
double asin(double x) { return atan2(x, sqrt((1 - x) * (1 + x))); }
double acos(double x) { return atan2(sqrt((1 - x) * (1 + x)), x); }

static long double log2l_x87(long double x) {
  long double r;
  __asm__("fld1; fxch; fyl2x" : "=t"(r) : "0"(x));
  return r;
}

static long double exp2l_x87(long double x) {
  long double i, f, r;
  __asm__("frndint" : "=t"(i) : "0"(x));
  f = x - i;
  __asm__("f2xm1" : "=t"(r) : "0"(f));
  r += 1;
  __asm__("fscale" : "=t"(r) : "0"(r), "u"(i));
  return r;
}

double log2(double x) { return x < 0 ? NAN : x == 0 ? -INFINITY : (double)log2l_x87(x); }
double log(double x) { return x < 0 ? NAN : x == 0 ? -INFINITY : (double)(log2l_x87(x) * 0.69314718055994530942L); }
double log10(double x) { return x < 0 ? NAN : x == 0 ? -INFINITY : (double)(log2l_x87(x) * 0.30102999566398119521L); }
double log1p(double x) { return log(1 + x); }

double exp(double x) {
  if (isnan(x)) return x;
  if (x > 709.8) return INFINITY;
  if (x < -745.2) return 0;
  return (double)exp2l_x87(x * 1.44269504088896340736L);
}

double expm1(double x) { return exp(x) - 1; }

double pow(double x, double y) {
  if (y == 0) return 1;
  if (x == 1) return 1;
  if (isnan(x) || isnan(y)) return NAN;
  if (x == 0) return y > 0 ? 0 : INFINITY;
  if (x < 0) {
    double i = trunc(y);
    if (i != y) return NAN;
    double r = (double)exp2l_x87(y * log2l_x87(-x));
    return fmod(i, 2) != 0 ? -r : r;
  }
  return (double)exp2l_x87(y * log2l_x87(x));
}

double fmod(double a, double b) {
  long double r;
  __asm__("1: fprem; fnstsw %%ax; testb $4, %%ah; jnz 1b" : "=t"(r) : "0"((long double)a), "u"((long double)b) : "ax", "cc");
  return (double)r;
}

double hypot(double a, double b) { return sqrt(a * a + b * b); }
double sinh(double x) { return (exp(x) - exp(-x)) / 2; }
double cosh(double x) { return (exp(x) + exp(-x)) / 2; }
double tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  double e = exp(2 * x);
  return (e - 1) / (e + 1);
}
double asinh(double x) { return x < 0 ? -log(-x + sqrt(x * x + 1)) : log(x + sqrt(x * x + 1)); }
double acosh(double x) { return log(x + sqrt(x * x - 1)); }
double atanh(double x) { return 0.5 * log((1 + x) / (1 - x)); }
double cbrt(double x) { return x < 0 ? -pow(-x, 1.0 / 3) : pow(x, 1.0 / 3); }
double ldexp(double x, int e) { return x * (double)exp2l_x87(e); }
double scalbn(double x, int e) { return ldexp(x, e); }

double frexp(double x, int *e) {
  if (x == 0 || isnan(x) || isinf(x)) { *e = 0; return x; }
  int k = 0;
  double m = fabs(x);
  while (m >= 1) m /= 2, k++;
  while (m < 0.5) m *= 2, k--;
  *e = k;
  return x < 0 ? -m : m;
}

double modf(double x, double *ip) {
  *ip = trunc(x);
  return x - *ip;
}

double nextafter(double x, double y) {
  if (isnan(x) || isnan(y)) return x + y;
  if (x == y) return y;
  union { double d; long long i; } u = {x};
  if (x == 0) u.i = 1, u.d = y > 0 ? u.d : -u.d;
  else if ((x < y) == (x > 0)) u.i++;
  else u.i--;
  return u.d;
}
