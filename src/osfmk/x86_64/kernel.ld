ENTRY(_start)
SECTIONS {
  . = 0xffffffff80000000;
  .text : { */kernel.o(.text.start) */kernel.o(.text .text.*) }
  .rodata : { */kernel.o(.rodata .rodata.*) }
  . = ALIGN(4096);
  .data : { */kernel.o(.data .data.*) }
  .bss : { */kernel.o(.bss .bss.* COMMON) }

  . = 0x0000100000000000;
  .utext : { *(.text .text.*) }
  .urodata : { *(.rodata .rodata.*) }
  . = ALIGN(4096);
  .udata : { *(.data .data.*) *(.got .got.*) }
  .tdata : { __tdata_start = .; *(.tdata .tdata.*) __tdata_end = .; }
  .tbss : { __tbss_start = .; *(.tbss .tbss.*) __tbss_end = .; }
  __tls_align = MAX(ALIGNOF(.tdata), ALIGNOF(.tbss));
  .ubss : { *(.bss .bss.*) *(COMMON) }
}
