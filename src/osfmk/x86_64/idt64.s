	.macro	TRAP vector
	.align	16
trap_\vector:
	pushq	$0
	pushq	$\vector
	jmp	trap_common
	.endm

	.macro	TRAP_ERR vector
	.align	16
trap_\vector:
	pushq	$\vector
	jmp	trap_common
	.endm

	.text
	TRAP 0
	TRAP 1
	TRAP 2
	TRAP 3
	TRAP 4
	TRAP 5
	TRAP 6
	TRAP 7
	TRAP_ERR 8
	TRAP 9
	TRAP_ERR 10
	TRAP_ERR 11
	TRAP_ERR 12
	TRAP_ERR 13
	TRAP_ERR 14
	TRAP 15
	TRAP 16
	TRAP_ERR 17
	TRAP 18
	TRAP 19
	TRAP 20
	TRAP_ERR 21
	TRAP 22
	TRAP 23
	TRAP 24
	TRAP 25
	TRAP 26
	TRAP 27
	TRAP 28
	TRAP_ERR 29
	TRAP_ERR 30
	TRAP 31
	TRAP 0x80
	TRAP 0x81
	TRAP 0x82
	TRAP 0x24
	TRAP 0xda
	TRAP 0xdd

trap_common:
	pushq	%r15
	pushq	%r14
	pushq	%r13
	pushq	%r12
	pushq	%r11
	pushq	%r10
	pushq	%r9
	pushq	%r8
	pushq	%rbp
	pushq	%rdi
	pushq	%rsi
	pushq	%rdx
	pushq	%rcx
	pushq	%rbx
	pushq	%rax
	movq	%rsp, %rdi
	call	kernel_trap
	.globl	return_to_user
return_to_user:
	popq	%rax
	popq	%rbx
	popq	%rcx
	popq	%rdx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r8
	popq	%r9
	popq	%r10
	popq	%r11
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	addq	$16, %rsp
	iretq

	.globl	idt64_stubs
	.data
	.align	8
idt64_stubs:
	.irp	v, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	.quad	trap_\v
	.endr
	.globl	idt64_syscall_stubs
idt64_syscall_stubs:
	.quad	trap_0x80, trap_0x81, trap_0x82
	.globl	idt64_interrupt_stubs
idt64_interrupt_stubs:
	.quad	0x24, trap_0x24, 0xda, trap_0xda, 0xdd, trap_0xdd, 0, 0

	.text
	.globl	gdt_load
gdt_load:
	lgdt	(%rdi)
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	xorw	%ax, %ax
	movw	%ax, %fs
	movw	%ax, %gs
	popq	%rax
	pushq	$0x08
	pushq	%rax
	lretq

	.globl	thread_bootstrap_return
thread_bootstrap_return:
	movw	$0x2b, %ax
	movw	%ax, %ds
	movw	%ax, %es
	pushq	$0x2b
	pushq	%rsi
	pushq	$0x202
	pushq	$0x33
	pushq	%rdi
	movq	%rdx, %rdi
	xorl	%esi, %esi
	xorl	%edx, %edx
	xorl	%eax, %eax
	xorl	%ebx, %ebx
	xorl	%ecx, %ecx
	xorl	%ebp, %ebp
	xorl	%r8d, %r8d
	xorl	%r9d, %r9d
	xorl	%r10d, %r10d
	xorl	%r11d, %r11d
	xorl	%r12d, %r12d
	xorl	%r13d, %r13d
	xorl	%r14d, %r14d
	xorl	%r15d, %r15d
	iretq
