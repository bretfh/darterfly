/* Static x86-64 Darterfly ABI, shared by native tools and their output.
   Keep PT_LOAD pages disjoint and never writable+executable. */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)
PHDRS {
  text PT_LOAD FLAGS(5);
  rodata PT_LOAD FLAGS(4);
  data PT_LOAD FLAGS(6);
  tls PT_TLS FLAGS(4);
  stack PT_GNU_STACK FLAGS(6);
}
SECTIONS {
  . = 0x400000;
  __dso_handle = .;
  .text : { *(.text .text.*) } :text
  . = ALIGN(4096);
  .rodata : { *(.rodata .rodata.*) *(.gcc_except_table .gcc_except_table.*) } :rodata
  .eh_frame : ALIGN(8) {
    __eh_frame_start = .;
    KEEP(*(.eh_frame))
    LONG(0)
    __eh_frame_end = .;
  } :rodata
  __eh_frame_hdr_start = 0;
  __eh_frame_hdr_end = 0;
  . = ALIGN(4096);
  .data : { *(.data .data.*) *(.got .got.*) } :data
  .preinit_array : ALIGN(8) {
    __preinit_array_start = .;
    KEEP(*(SORT_BY_INIT_PRIORITY(.preinit_array.*))) KEEP(*(.preinit_array))
    __preinit_array_end = .;
  } :data
  .init_array : ALIGN(8) {
    __init_array_start = .;
    KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*))) KEEP(*(.init_array))
    __init_array_end = .;
  } :data
  .fini_array : ALIGN(8) {
    __fini_array_start = .;
    KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*))) KEEP(*(.fini_array))
    __fini_array_end = .;
  } :data
  /* libsa's variant-II TLS rounds the block to at least 16 bytes. */
  .tdata ALIGN(MAX(16, MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)))) : ALIGN(16) {
    __tdata_start = .; *(.tdata .tdata.*) __tdata_end = .;
  } :data :tls
  .tbss : {
    __tbss_start = .; *(.tbss .tbss.*) __tbss_end = .;
  } :data :tls
  __tls_align = MAX(16, MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)));
  /* Include TLS zero fill in the containing PT_LOAD memory range. */
  . = __tbss_end;
  .bss : { *(.bss .bss.*) *(COMMON) } :data
  /DISCARD/ : { *(.note.GNU-stack) }
}
