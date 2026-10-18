.text
.global native_call
native_call:
    mov %rcx, %r10
    mov $41, %eax
    int $0x82
    ret
.section .note.GNU-stack,"",@progbits
