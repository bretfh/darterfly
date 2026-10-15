#include <math.h>
#include <stdint.h>

static inline unsigned short x87_enter(void) {
  unsigned short cw, masked;
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  masked = cw | 0x3f;
  __asm__ volatile("fnclex; fldcw %0" ::"m"(masked));
  return cw;
}

static inline void x87_leave(unsigned short cw) { __asm__ volatile("fnclex; fldcw %0" ::"m"(cw)); }

#define X87(expr)                  \
  ({                               \
    unsigned short cw_ = x87_enter(); \
    __typeof__(expr) r_ = (expr);  \
    x87_leave(cw_);                \
    r_;                            \
  })

#define X87_1(name, insn)                                       \
  double name(double x) {                                       \
    double r;                                                   \
    __asm__("fldl %1\n\t" insn "\n\tfstpl %0" : "=m"(r) : "m"(x)); \
    return r;                                                   \
  }

X87_1(sqrt_x87, "fsqrt")
X87_1(sin_x87, "fsin")
X87_1(cos_x87, "fcos")

double sqrt(double x) { return sqrt_x87(x); }
float sqrtf(float x) { return (float)sqrt_x87(x); }

double fabs(double x) {
  union { double d; uint64_t u; } v = {x};
  v.u &= ~(1ull << 63);
  return v.d;
}

float fabsf(float x) {
  union { float f; uint32_t u; } v = {x};
  v.u &= ~(1u << 31);
  return v.f;
}

double copysign(double a, double b) {
  union { double d; uint64_t u; } x = {a}, y = {b};
  x.u = (x.u & ~(1ull << 63)) | (y.u & (1ull << 63));
  return x.d;
}

static double round_mode_raw(double x, unsigned short mode) {
  long double r;
  unsigned short cw, ncw;
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  ncw = (cw & ~0x0c00) | mode;
  __asm__ volatile("fldcw %0" ::"m"(ncw));
  long double lx = x;
  __asm__ volatile("fldt %1; frndint; fstpt %0" : "=m"(r) : "m"(lx));
  __asm__ volatile("fldcw %0" ::"m"(cw));
  return (double)r;
}

static double round_mode(double x, unsigned short mode) { return X87(round_mode_raw(x, mode)); }

double floor(double x) { return round_mode(x, 0x0400); }
double ceil(double x) { return round_mode(x, 0x0800); }
double trunc(double x) { return round_mode(x, 0x0c00); }
double rint(double x) { return round_mode(x, 0x0000); }
double round(double x) { return x < 0 ? -floor(-x + 0.5) : floor(x + 0.5); }
long lrint(double x) { return (long)rint(x); }
float floorf(float x) { return (float)floor(x); }
float ceilf(float x) { return (float)ceil(x); }
float truncf(float x) { return (float)trunc(x); }
long double truncl(long double x) {
  unsigned short cw = x87_enter(), t = (unsigned short)(cw | 0x0c00 | 0x3f);
  long double r;
  __asm__ volatile("fldcw %0" ::"m"(t));
  __asm__ volatile("fldt %1; frndint; fstpt %0" : "=m"(r) : "m"(x));
  x87_leave(cw);
  return r;
}

double sin(double x) { return X87(sin_x87(x)); }
double cos(double x) { return X87(cos_x87(x)); }

static double tan_raw(double x) {
  long double r, lx = x;
  __asm__("fldt %1; fptan; fstp %%st(0); fstpt %0" : "=m"(r) : "m"(lx));
  return (double)r;
}

static double atan2_raw(double y, double x) {
  long double r, lx = x, ly = y;
  __asm__("fldt %1; fldt %2; fpatan; fstpt %0" : "=m"(r) : "m"(ly), "m"(lx));
  return (double)r;
}

double tan(double x) { return X87(tan_raw(x)); }
double atan2(double y, double x) { return X87(atan2_raw(y, x)); }
double atan(double x) { return atan2(x, 1.0); }
double asin(double x) { return atan2(x, sqrt((1 - x) * (1 + x))); }
double acos(double x) { return atan2(sqrt((1 - x) * (1 + x)), x); }

static long double log2l_x87(long double x) {
  long double r;
  __asm__("fld1; fldt %1; fyl2x; fstpt %0" : "=m"(r) : "m"(x));
  return r;
}

static long double exp2l_x87(long double x) {
  long double i, f, r;
  __asm__("fldt %1; frndint; fstpt %0" : "=m"(i) : "m"(x));
  f = x - i;
  __asm__("fldt %1; f2xm1; fstpt %0" : "=m"(r) : "m"(f));
  r += 1;
  {
    long double m = r;
    __asm__("fldt %2; fldt %1; fscale; fstp %%st(1); fstpt %0" : "=m"(r) : "m"(m), "m"(i));
  }
  return r;
}

double log2(double x) { return x < 0 ? NAN : x == 0 ? -INFINITY : (double)X87(log2l_x87(x)); }
double log(double x) { return x < 0 ? NAN : x == 0 ? -INFINITY : (double)X87(log2l_x87(x) * 0.69314718055994530942L); }
double log10(double x) { return x < 0 ? NAN : x == 0 ? -INFINITY : (double)X87(log2l_x87(x) * 0.30102999566398119521L); }
double log1p(double x) { return log(1 + x); }

double exp(double x) {
  if (isnan(x)) return x;
  if (x > 709.8) return INFINITY;
  if (x < -745.2) return 0;
  return (double)X87(exp2l_x87(x * 1.44269504088896340736L));
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
    double r = (double)X87(exp2l_x87(y * log2l_x87(-x)));
    return fmod(i, 2) != 0 ? -r : r;
  }
  return (double)X87(exp2l_x87(y * log2l_x87(x)));
}

static double fmod_raw(double a, double b) {
  long double r;
  long double la = a, lb = b;
  __asm__("fldt %2; fldt %1; 1: fprem; fnstsw %%ax; testb $4, %%ah; jnz 1b; fstp %%st(1); fstpt %0"
          : "=m"(r) : "m"(la), "m"(lb) : "ax", "cc");
  return (double)r;
}

double fmod(double a, double b) { return X87(fmod_raw(a, b)); }
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
double ldexp(double x, int e) { return x * (double)X87(exp2l_x87(e)); }
double scalbn(double x, int e) { return ldexp(x, e); }
long double ldexpl(long double x, int e) {
  long double r;
  __asm__("fildl %2\n\tfldt %1\n\tfscale\n\tfstp %%st(1)\n\tfstpt %0" : "=m"(r) : "m"(x), "m"(e));
  return r;
}

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
