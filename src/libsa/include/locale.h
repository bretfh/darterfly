#pragma once
#include <stddef.h>
#include <time.h>
#include <stdlib.h>
#ifdef __cplusplus
extern "C" {
#endif
#define LC_CTYPE 0
#define LC_NUMERIC 1
#define LC_TIME 2
#define LC_COLLATE 3
#define LC_MONETARY 4
#define LC_MESSAGES 5
#define LC_ALL 6
#define LC_CTYPE_MASK (1 << LC_CTYPE)
#define LC_NUMERIC_MASK (1 << LC_NUMERIC)
#define LC_TIME_MASK (1 << LC_TIME)
#define LC_COLLATE_MASK (1 << LC_COLLATE)
#define LC_MONETARY_MASK (1 << LC_MONETARY)
#define LC_MESSAGES_MASK (1 << LC_MESSAGES)
#define LC_ALL_MASK 63
typedef void *locale_t;
#define LC_GLOBAL_LOCALE ((locale_t)-1)
struct lconv {
  char *decimal_point, *thousands_sep, *grouping, *int_curr_symbol;
  char *currency_symbol, *mon_decimal_point, *mon_thousands_sep, *mon_grouping;
  char *positive_sign, *negative_sign;
  char int_frac_digits, frac_digits, p_cs_precedes, p_sep_by_space;
  char n_cs_precedes, n_sep_by_space, p_sign_posn, n_sign_posn;
  char int_p_cs_precedes, int_p_sep_by_space, int_n_cs_precedes;
  char int_n_sep_by_space, int_p_sign_posn, int_n_sign_posn;
};
char *setlocale(int, const char *);
struct lconv *localeconv(void);
locale_t newlocale(int, const char *, locale_t);
locale_t uselocale(locale_t);
void freelocale(locale_t);
int wcscoll_l(const wchar_t *, const wchar_t *, locale_t);
size_t wcsxfrm_l(wchar_t *, const wchar_t *, size_t, locale_t);
int strcoll_l(const char *, const char *, locale_t);
size_t strxfrm_l(char *, const char *, size_t, locale_t);
size_t strftime_l(char *, size_t, const char *, const struct tm *, locale_t);
static inline float strtof_l(const char *s, char **end, locale_t loc) {
  (void)loc; return strtof(s, end);
}
static inline double strtod_l(const char *s, char **end, locale_t loc) {
  (void)loc; return strtod(s, end);
}
static inline long double strtold_l(const char *s, char **end, locale_t loc) {
  (void)loc; return strtold(s, end);
}
static inline long long strtoll_l(const char *s, char **end, int base, locale_t loc) {
  (void)loc; return strtoll(s, end, base);
}
static inline unsigned long long strtoull_l(const char *s, char **end, int base, locale_t loc) {
  (void)loc; return strtoull(s, end, base);
}
#ifdef __cplusplus
}
#endif
