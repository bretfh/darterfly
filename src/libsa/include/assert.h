#pragma once
void __assert_fail(const char *, const char *, unsigned, const char *) __attribute__((noreturn));
#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((e) ? (void)0 : __assert_fail(#e, __FILE__, __LINE__, __func__))
#endif
#define static_assert _Static_assert
