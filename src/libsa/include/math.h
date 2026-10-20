#pragma once
#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4
#ifdef __cplusplus
extern "C" {
#endif
#define HUGE_VALF __builtin_huge_valf()
#define HUGE_VALL __builtin_huge_vall()
#define HUGE_VAL __builtin_huge_val()
#define INFINITY __builtin_huge_valf()
#define NAN __builtin_nanf("")
#define isnan(x) ((x) != (x))
#define isinf(x) ((x) == __builtin_huge_val() || (x) == -__builtin_huge_val())
#define isfinite(x) (!isnan(x) && !isinf(x))
static inline int __libsa_fpclassify(long double x, long double min) {
  if (x != x) return FP_NAN;
  if (x == HUGE_VALL || x == -HUGE_VALL) return FP_INFINITE;
  if (x == 0) return FP_ZERO;
  return (x < 0 ? -x : x) < min ? FP_SUBNORMAL : FP_NORMAL;
}
#define fpclassify(x) __libsa_fpclassify((x), sizeof(x) == sizeof(float) ? \
    0x1p-126L : sizeof(x) == sizeof(double) ? 0x1p-1022L : 0x1p-16382L)
#define signbit(x) __libsa_signbit((double)(x))
static inline int __libsa_signbit(double x) {
  union { double d; unsigned long u; } v = {x};
  return (int)(v.u >> 63);
}
double nan(const char *);
float nanf(const char *);
#define M_PI 3.14159265358979323846
double sin(double), cos(double), tan(double), asin(double), acos(double), atan(double), atan2(double, double);
double sinh(double), cosh(double), tanh(double), asinh(double), acosh(double), atanh(double);
double exp(double), expm1(double), log(double), log10(double), log2(double), log1p(double);
double pow(double, double), sqrt(double), hypot(double, double), cbrt(double);
double floor(double), ceil(double), trunc(double), round(double), fabs(double), fmod(double, double);
double ldexp(double, int), frexp(double, int *), modf(double, double *), scalbn(double, int);
long double ldexpl(long double, int), frexpl(long double, int *);
double fmin(double, double), fmax(double, double);
float fminf(float, float), fmaxf(float, float);
double copysign(double, double), nextafter(double, double), rint(double);
long lrint(double);
long long llround(double);
double remainder(double, double);
float erff(float), ldexpf(float, int), frexpf(float, int *);
double fma(double, double, double);
float fmodf(float, float), powf(float, float), copysignf(float, float);
float acosf(float), asinf(float), log10f(float), log2f(float), cbrtf(float);
float fmaf(float, float, float);
long lrintf(float);
long long llroundf(float);
float tanhf(float), sinf(float), cosf(float), tanf(float), atanf(float), hypotf(float, float);
float expf(float), exp2f(float), logf(float), remainderf(float, float);
float atan2f(float, float);
long double atan2l(long double, long double), hypotl(long double, long double);
float nextafterf(float, float), roundf(float), rintf(float);
long lroundf(float);
float sqrtf(float), fabsf(float), floorf(float), ceilf(float), truncf(float);
long double truncl(long double);

#ifdef __cplusplus
}
#endif
