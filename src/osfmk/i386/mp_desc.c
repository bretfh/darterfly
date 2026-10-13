#include "../../pexpert/i386/pexpert.h"
#include "seg.h"

struct __attribute__((packed)) x86_64_tss {
  uint32_t reserved1;
  uint64_t rsp0, rsp1, rsp2;
  uint64_t reserved2;
  uint64_t ist1, ist2, ist3, ist4, ist5, ist6, ist7;
  uint64_t reserved3;
  uint16_t reserved4;
  uint16_t io_bit_map_offset;
};

struct __attribute__((packed)) real_gate64 {
  uint16_t offset_low16, selector16;
  uint8_t ist, access;
  uint16_t offset_high16;
  uint32_t offset_top32, reserved32;
};

struct __attribute__((packed)) pseudo_descriptor {
  uint16_t limit;
  uint64_t base;
};

static uint64_t master_gdt[7] __attribute__((aligned(16)));
static uint8_t kernel_stack[65536] __attribute__((aligned(16)));
static struct x86_64_tss master_ktss __attribute__((aligned(16)));
static struct real_gate64 master_idt64[256] __attribute__((aligned(16)));
static uint8_t df_stack[16384] __attribute__((aligned(16)));

extern uint64_t idt64_stubs[32];
extern uint64_t idt64_syscall_stubs[3];
extern uint64_t idt64_interrupt_stubs[];
extern void gdt_load(struct pseudo_descriptor *);

void set_kernel_stack(uint64_t top) { master_ktss.rsp0 = top; }

uint64_t boot_kernel_stack_top(void) { return (uint64_t)(kernel_stack + sizeof kernel_stack); }

void mp_desc_init(void) {
  master_gdt[0] = 0;
  master_gdt[1] = 0x00209a0000000000ull;
  master_gdt[2] = 0x0000920000000000ull;
  uint64_t tss = (uint64_t)&master_ktss;
  uint64_t limit = sizeof master_ktss - 1;
  master_gdt[3] = (limit & 0xffff) | ((tss & 0xffffff) << 16) | (0x89ull << 40) | (((tss >> 24) & 0xff) << 56);
  master_gdt[4] = tss >> 32;
  master_gdt[5] = 0x0000f20000000000ull;
  master_gdt[6] = 0x0020fa0000000000ull;
  master_ktss.rsp0 = (uint64_t)(kernel_stack + sizeof kernel_stack);
  master_ktss.ist1 = (uint64_t)(df_stack + sizeof df_stack);
  master_ktss.io_bit_map_offset = sizeof master_ktss;

  struct pseudo_descriptor gdtr = {sizeof master_gdt - 1, (uint64_t)master_gdt};
  gdt_load(&gdtr);
  __asm__ volatile("ltr %w0" ::"r"(KERNEL_TSS));

  for (int v = 0; v < 32; v++) {
    uint64_t at = idt64_stubs[v];
    master_idt64[v] = (struct real_gate64){
        .offset_low16 = (uint16_t)at,
        .selector16 = KERNEL64_CS,
        .ist = v == 8 ? 1 : 0,
        .access = (v == 3 || v == 4) ? 0xee : 0x8e,
        .offset_high16 = (uint16_t)(at >> 16),
        .offset_top32 = (uint32_t)(at >> 32),
    };
  }
  for (int i = 0; i < 3; i++) {
    uint64_t at = idt64_syscall_stubs[i];
    master_idt64[0x80 + i] = (struct real_gate64){
        .offset_low16 = (uint16_t)at,
        .selector16 = KERNEL64_CS,
        .access = 0xee,
        .offset_high16 = (uint16_t)(at >> 16),
        .offset_top32 = (uint32_t)(at >> 32),
    };
  }
  for (uint64_t *e = idt64_interrupt_stubs; e[1]; e += 2) {
    uint64_t at = e[1];
    master_idt64[e[0]] = (struct real_gate64){
        .offset_low16 = (uint16_t)at,
        .selector16 = KERNEL64_CS,
        .access = 0x8e,
        .offset_high16 = (uint16_t)(at >> 16),
        .offset_top32 = (uint32_t)(at >> 32),
    };
  }
  struct pseudo_descriptor idtr = {sizeof master_idt64 - 1, (uint64_t)master_idt64};
  __asm__ volatile("lidt %0" ::"m"(idtr));
}
