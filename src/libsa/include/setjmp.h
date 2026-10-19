#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef unsigned long jmp_buf[8];
typedef unsigned long sigjmp_buf[8 + 1 + 16];
int setjmp(jmp_buf) __attribute__((returns_twice));
void longjmp(jmp_buf, int) __attribute__((noreturn));
int sigsetjmp(sigjmp_buf, int) __attribute__((returns_twice));
void siglongjmp(sigjmp_buf, int) __attribute__((noreturn));
#define _setjmp setjmp
#define _longjmp longjmp

#ifdef __cplusplus
}
#endif
