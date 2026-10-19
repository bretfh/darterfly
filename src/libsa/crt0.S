/* SysV executable entry; all runtime initialization lives in libsa. */
.text
.global _start
_start:
    xor %ebp, %ebp
    mov (%rsp), %rdi
    lea 8(%rsp), %rsi
    lea 16(%rsp,%rdi,8), %rdx
    call __libsa_native_start
    ud2
.section .note.GNU-stack,"",@progbits
