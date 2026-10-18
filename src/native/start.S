/* Darterfly static native ABI v0: SysV entry stack, int 0x80 exit. */
.text
.global _start
_start:
    xor %ebp, %ebp
    mov (%rsp), %rdi
    lea 8(%rsp), %rsi
    lea 16(%rsp,%rdi,8), %rdx
    mov %rdx, environ(%rip)
    call main
    mov %eax, %edi
    mov $1, %eax
    int $0x80
    ud2

/* long native_call(port, request, length, reply, capacity) */
.global native_call
native_call:
    mov %rcx, %r10
    mov $41, %eax
    int $0x82
    ret
/* Variadic APIs with only integer arguments: preserve the optional RDX. */
.global open
open:
    jmp __native_open
.global fcntl
fcntl:
    jmp __native_fcntl
.section .note.GNU-stack,"",@progbits
