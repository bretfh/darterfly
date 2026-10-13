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

	.section .rodata
	.globl	slave_boot_base, slave_boot_end, slave_cr3, slave_rsp, slave_cpu, slave_entry
	.code16
slave_boot_base:
	cli
	movw	%cs, %ax
	movw	%ax, %ds
	movw	%ax, %ss
	movw	$0x1000, %sp
	xorl	%ebx, %ebx
	movw	%cs, %bx
	shll	$4, %ebx
	leal	(slave_gdt - slave_boot_base)(%ebx), %eax
	movl	%eax, (slave_gdtr - slave_boot_base + 2)
	lgdtl	(slave_gdtr - slave_boot_base)
	movl	%cr0, %eax
	orl	$1, %eax
	movl	%eax, %cr0
	leal	(slave_pstart - slave_boot_base)(%ebx), %eax
	pushl	$0x08
	pushl	%eax
	lretl

	.code32
slave_pstart:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	leal	0x1000(%ebx), %esp
	movl	%cr4, %eax
	orl	$0x20, %eax
	movl	%eax, %cr4
	movl	(slave_cr3 - slave_boot_base)(%ebx), %eax
	movl	%eax, %cr3
	movl	$0xc0000080, %ecx
	rdmsr
	orl	$0x900, %eax
	wrmsr
	movl	%cr0, %eax
	orl	$0x80000000, %eax
	movl	%eax, %cr0
	leal	(slave_start - slave_boot_base)(%ebx), %eax
	pushl	$0x18
	pushl	%eax
	lret

	.code64
slave_start:
	movl	%ebx, %ebx
	movq	(slave_rsp - slave_boot_base)(%rbx), %rsp
	movq	(slave_cpu - slave_boot_base)(%rbx), %rdi
	movq	(slave_entry - slave_boot_base)(%rbx), %rax
	jmp	*%rax

	.align	8
slave_gdt:
	.quad	0
	.quad	0x00cf9a000000ffff
	.quad	0x00cf92000000ffff
	.quad	0x00209a0000000000
slave_gdtr:
	.word	31
	.long	0
	.align	8
slave_cr3:
	.long	0, 0
slave_rsp:
	.quad	0
slave_cpu:
	.quad	0
slave_entry:
	.quad	0
slave_boot_end:
