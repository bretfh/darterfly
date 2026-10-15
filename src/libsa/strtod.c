#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define LIMBS 720
#define MAX_DIGITS 800

typedef struct { int n; uint32_t d[LIMBS]; } big;

static void big_set(big *a, uint32_t v) { a->n = v != 0; a->d[0] = v; }

static void big_trim(big *a) { while (a->n && !a->d[a->n - 1]) a->n--; }

static void big_muladd(big *a, uint32_t m, uint32_t add) {
  uint64_t carry = add;
  for (int i = 0; i < a->n; i++) {
    uint64_t t = (uint64_t)a->d[i] * m + carry;
    a->d[i] = (uint32_t)t;
    carry = t >> 32;
  }
  if (carry) a->d[a->n++] = (uint32_t)carry;
}

static void big_pow10(big *a, int e) {
  for (; e >= 9; e -= 9) big_muladd(a, 1000000000u, 0);
  static const uint32_t small[9] = {1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000};
  if (e) big_muladd(a, small[e], 0);
}

static int big_bits(const big *a) {
  if (!a->n) return 0;
  int bits = (a->n - 1) * 32;
  for (uint32_t top = a->d[a->n - 1]; top; top >>= 1) bits++;
  return bits;
}

static void big_shl(big *a, int s) {
  if (!a->n || !s) return;
  int w = s / 32, b = s % 32;
  int n = a->n + w + 1;
  for (int i = n - 1; i >= 0; i--) {
    uint32_t hi = i - w >= 0 && i - w < a->n ? a->d[i - w] : 0;
    uint32_t lo = i - w - 1 >= 0 && i - w - 1 < a->n ? a->d[i - w - 1] : 0;
    a->d[i] = b ? (hi << b) | (lo >> (32 - b)) : hi;
  }
  a->n = n;
  big_trim(a);
}

static int big_cmp(const big *a, const big *b) {
  if (a->n != b->n) return a->n < b->n ? -1 : 1;
  for (int i = a->n - 1; i >= 0; i--)
    if (a->d[i] != b->d[i]) return a->d[i] < b->d[i] ? -1 : 1;
  return 0;
}

static void big_sub(big *a, const big *b) {
  int64_t borrow = 0;
  for (int i = 0; i < a->n; i++) {
    int64_t t = (int64_t)a->d[i] - (i < b->n ? b->d[i] : 0) - borrow;
    borrow = t < 0;
    a->d[i] = (uint32_t)(t + (borrow ? ((int64_t)1 << 32) : 0));
  }
  big_trim(a);
}

static uint64_t big_low(const big *a, int bits) {
  uint64_t v = 0;
  for (int i = 0; i < 2 && i < a->n; i++) v |= (uint64_t)a->d[i] << (32 * i);
  return bits >= 64 ? v : v & ((1ull << bits) - 1);
}

static int big_bit(const big *a, int i) { return i / 32 < a->n && ((a->d[i / 32] >> (i % 32)) & 1); }

static int big_low_nonzero(const big *a, int bits) {
  for (int i = 0; i < bits / 32 && i < a->n; i++)
    if (a->d[i]) return 1;
  int rest = bits % 32;
  return rest && bits / 32 < a->n && (a->d[bits / 32] & ((1u << rest) - 1));
}

static uint64_t big_div(big *num, const big *den) {
  uint64_t q = 0;
  big shifted;
  for (int i = big_bits(num) - big_bits(den); i >= 0; i--) {
    shifted = *den;
    big_shl(&shifted, i);
    if (big_cmp(num, &shifted) >= 0) {
      big_sub(num, &shifted);
      q |= 1ull << i;
    }
  }
  return q;
}

static int round_decimal(big *m, int e10, int p, int emin, uint64_t *mant, int *exp2) {
  big den;
  int lead;
  if (e10 >= 0) {
    big_pow10(m, e10);
    lead = big_bits(m) - 1;
  } else {
    big_set(&den, 1);
    big_pow10(&den, -e10);
    int s = big_bits(m) - big_bits(&den);
    big t = s >= 0 ? den : *m;
    big_shl(&t, s >= 0 ? s : -s);
    lead = (s >= 0 ? big_cmp(m, &t) : big_cmp(&t, &den)) >= 0 ? s : s - 1;
  }
  int e = (lead < emin ? emin : lead) - p + 1;
  uint64_t q;
  int cmp;
  if (e10 >= 0 && e >= 0) {
    q = 0;
    for (int i = 0; i < p && e + i <= lead; i++) q |= (uint64_t)big_bit(m, e + i) << i;
    if (e == 0) cmp = -1;
    else if (!big_bit(m, e - 1)) cmp = -1;
    else cmp = big_low_nonzero(m, e - 1) ? 1 : 0;
  } else if (e10 >= 0) {
    big_shl(m, -e);
    q = big_low(m, 64);
    cmp = -1;
  } else {
    if (e >= 0) big_shl(&den, e);
    else big_shl(m, -e);
    q = big_div(m, &den);
    big_shl(m, 1);
    cmp = big_cmp(m, &den);
  }
  if (cmp > 0 || (cmp == 0 && (q & 1))) {
    q++;
    if (q == 0 || (p < 64 && q == 1ull << p)) {
      q = 1ull << (p - 1);
      e++;
    }
  }
  *mant = q;
  *exp2 = e;
  return lead;
}

typedef struct { int sign, special; big m; int e10; const char *end; } decimal;

static int match(const char *p, const char *word) {
  for (; *word; p++, word++)
    if (tolower((unsigned char)*p) != *word) return 0;
  return 1;
}

static void parse(const char *s, decimal *d) {
  const char *p = s;
  while (isspace((unsigned char)*p)) p++;
  d->sign = 0;
  if (*p == '+' || *p == '-') d->sign = *p++ == '-';
  d->special = 0;
  d->e10 = 0;
  big_set(&d->m, 0);
  if (match(p, "inf")) {
    d->special = 1;
    d->end = p + (match(p, "infinity") ? 8 : 3);
    return;
  }
  if (match(p, "nan")) {
    d->special = 2;
    d->end = p + 3;
    return;
  }
  int digits = 0, seen = 0, sticky = 0;
  for (int dot = 0;; p++) {
    if (*p == '.' && !dot) { dot = 1; continue; }
    if (!isdigit((unsigned char)*p)) break;
    seen = 1;
    if (digits < MAX_DIGITS) {
      if (digits || *p != '0') {
        big_muladd(&d->m, 10, *p - '0');
        digits++;
      }
      if (dot) d->e10--;
    } else {
      if (*p != '0') sticky = 1;
      if (!dot) d->e10++;
    }
  }
  if (!seen) {
    d->end = s;
    return;
  }
  if (sticky) {
    big_muladd(&d->m, 10, 1);
    d->e10--;
  }
  if (*p == 'e' || *p == 'E') {
    const char *q = p + 1;
    int neg = 0;
    if (*q == '+' || *q == '-') neg = *q++ == '-';
    if (isdigit((unsigned char)*q)) {
      long x = 0;
      for (; isdigit((unsigned char)*q); q++) if (x < 100000) x = x * 10 + (*q - '0');
      d->e10 += neg ? -x : x;
      p = q;
    }
  }
  d->end = p;
}

static int convert(decimal *d, int p, int emin, int emax, uint64_t *mant, int *exp2) {
  if (!d->m.n) return 0;
  int magnitude = d->e10 + (big_bits(&d->m) * 3) / 10;
  if (magnitude > emax / 3 + 2) return 2;
  if (magnitude < (emin - p) / 3 - 2) return 0;
  round_decimal(&d->m, d->e10, p, emin, mant, exp2);
  if (*mant == 0) return 0;
  if (*exp2 + p - 1 > emax) return 2;
  return 1;
}

double strtod(const char *s, char **end) {
  decimal d;
  parse(s, &d);
  if (end) *end = (char *)d.end;
  union { double v; uint64_t u; } r = {0};
  if (d.special == 1) r.u = 0x7ffull << 52;
  else if (d.special == 2) r.u = 0x7ff8ull << 48;
  else {
    uint64_t mant;
    int e, kind = convert(&d, 53, -1022, 1023, &mant, &e);
    if (kind == 2) { r.u = 0x7ffull << 52; errno = ERANGE; }
    else if (kind == 1) {
      if (mant >> 52) r.u = ((uint64_t)(e + 52 + 1023) << 52) | (mant & ((1ull << 52) - 1));
      else r.u = mant;
    } else if (d.m.n) errno = ERANGE;
  }
  if (d.sign) r.u |= 1ull << 63;
  return r.v;
}

float strtof(const char *s, char **end) {
  decimal d;
  parse(s, &d);
  if (end) *end = (char *)d.end;
  union { float v; uint32_t u; } r = {0};
  if (d.special == 1) r.u = 0xffu << 23;
  else if (d.special == 2) r.u = 0x7fc00000u;
  else {
    uint64_t mant;
    int e, kind = convert(&d, 24, -126, 127, &mant, &e);
    if (kind == 2) { r.u = 0xffu << 23; errno = ERANGE; }
    else if (kind == 1) {
      if (mant >> 23) r.u = ((uint32_t)(e + 23 + 127) << 23) | ((uint32_t)mant & ((1u << 23) - 1));
      else r.u = (uint32_t)mant;
    } else if (d.m.n) errno = ERANGE;
  }
  if (d.sign) r.u |= 1u << 31;
  return r.v;
}

long double strtold(const char *s, char **end) {
  decimal d;
  parse(s, &d);
  if (end) *end = (char *)d.end;
  struct { uint64_t m; uint16_t se; } r = {0, 0};
  if (d.special == 1) { r.m = 1ull << 63; r.se = 0x7fff; }
  else if (d.special == 2) { r.m = 3ull << 62; r.se = 0x7fff; }
  else {
    uint64_t mant;
    int e, kind = convert(&d, 64, -16382, 16383, &mant, &e);
    if (kind == 2) { r.m = 1ull << 63; r.se = 0x7fff; errno = ERANGE; }
    else if (kind == 1) {
      r.m = mant;
      r.se = mant >> 63 ? (uint16_t)(e + 63 + 16383) : 0;
    } else if (d.m.n) errno = ERANGE;
  }
  if (d.sign) r.se |= 0x8000;
  long double v;
  memcpy(&v, &r, 10);
  return v;
}
