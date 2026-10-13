#pragma once
#include <stdint.h>
typedef uint64_t Elf64_Addr, Elf64_Off, Elf64_Xword;
typedef int64_t Elf64_Sxword;
typedef uint32_t Elf64_Word;
typedef uint16_t Elf64_Half;
typedef struct {
  unsigned char e_ident[16];
  Elf64_Half e_type, e_machine;
  Elf64_Word e_version;
  Elf64_Addr e_entry;
  Elf64_Off e_phoff, e_shoff;
  Elf64_Word e_flags;
  Elf64_Half e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} Elf64_Ehdr;
typedef struct {
  Elf64_Word sh_name, sh_type;
  Elf64_Xword sh_flags;
  Elf64_Addr sh_addr;
  Elf64_Off sh_offset;
  Elf64_Xword sh_size;
  Elf64_Word sh_link, sh_info;
  Elf64_Xword sh_addralign, sh_entsize;
} Elf64_Shdr;
typedef struct {
  Elf64_Word p_type, p_flags;
  Elf64_Off p_offset;
  Elf64_Addr p_vaddr, p_paddr;
  Elf64_Xword p_filesz, p_memsz, p_align;
} Elf64_Phdr;
typedef struct {
  Elf64_Word st_name;
  unsigned char st_info, st_other;
  Elf64_Half st_shndx;
  Elf64_Addr st_value;
  Elf64_Xword st_size;
} Elf64_Sym;
typedef struct {
  Elf64_Addr r_offset;
  Elf64_Xword r_info;
  Elf64_Sxword r_addend;
} Elf64_Rela;
#define SHT_NULL 0
#define SHT_PROGBITS 1
#define SHT_SYMTAB 2
#define SHT_STRTAB 3
#define SHT_RELA 4
#define SHT_NOBITS 8
#define PT_LOAD 1
#define ELFMAG "\177ELF"
#define SELFMAG 4
#define STB_LOCAL 0
#define STB_GLOBAL 1
#define STT_NOTYPE 0
#define STT_OBJECT 1
#define STT_FUNC 2
#define ELF64_ST_INFO(b, t) (((b) << 4) + ((t) & 0xf))
#define ELF64_R_SYM(i) ((i) >> 32)
#define ELF64_R_TYPE(i) ((i) & 0xffffffff)
#define SHN_UNDEF 0
#define SHN_ABS 0xfff1
#define R_X86_64_64 1
#define R_X86_64_PC32 2
#define SHF_WRITE 1
#define SHF_ALLOC 2
#define SHF_EXECINSTR 4
#define ELFMAG0 0x7f
#define ELFMAG1 'E'
#define ELFMAG2 'L'
#define ELFMAG3 'F'
#define ELFCLASS64 2
#define ELFDATA2LSB 1
#define EV_CURRENT 1
#define ET_REL 1
#define ET_EXEC 2
#define EM_X86_64 62
#define EI_CLASS 4
#define EI_DATA 5
#define EI_VERSION 6
#define EI_OSABI 7
#define ELFOSABI_NONE 0
#define ELF64_R_INFO(s, t) (((uint64_t)(s) << 32) + (t))
