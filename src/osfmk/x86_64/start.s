	.section .text.start, "ax"
	.globl _start
_start:
	cli
	lea	stack_top(%rip), %rsp
	xor	%ebp, %ebp
	call	i386_init
1:	hlt
	jmp	1b

	.bss
	.align 16
stack:
	.space 65536
stack_top:
