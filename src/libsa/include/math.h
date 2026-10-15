#pragma once
#define HUGE_VAL __builtin_huge_val()
#define INFINITY __builtin_huge_valf()
#define NAN __builtin_nanf("")
#define isnan(x) ((x) != (x))
#define isinf(x) ((x) == __builtin_huge_val() || (x) == -__builtin_huge_val())
#define isfinite(x) (!isnan(x) && !isinf(x))
#define signbit(x) __libsa_signbit((double)(x))
static inline int __libsa_signbit(double x) {
  union { double d; unsigned long u; } v = {x};
  return (int)(v.u >> 63);
}
#define M_PI 3.14159265358979323846
double sin(double), cos(double), tan(double), asin(double), acos(double), atan(double), atan2(double, double);
double sinh(double), cosh(double), tanh(double), asinh(double), acosh(double), atanh(double);
double exp(double), expm1(double), log(double), log10(double), log2(double), log1p(double);
double pow(double, double), sqrt(double), hypot(double, double), cbrt(double);
double floor(double), ceil(double), trunc(double), round(double), fabs(double), fmod(double, double);
double ldexp(double, int), frexp(double, int *), modf(double, double *), scalbn(double, int);
double copysign(double, double), nextafter(double, double), rint(double);
long lrint(double);
float sqrtf(float), fabsf(float), floorf(float), ceilf(float), truncf(float);
long double truncl(long double);
