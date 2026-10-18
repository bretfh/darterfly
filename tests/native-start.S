/* Darterfly static native ABI v0: SysV entry stack, int 0x80 exit. */
.text
.global _start
_start:
    xor %ebp, %ebp
    mov (%rsp), %rdi
    lea 8(%rsp), %rsi
    lea 16(%rsp,%rdi,8), %rdx
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
.section .note.GNU-stack,"",@progbits
