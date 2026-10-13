#include "../../pexpert/i386/pexpert.h"
#include "seg.h"
#include "cpu_data.h"

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

cpu_data_t cpu_data_master[MAX_CPUS] __attribute__((aligned(64)));
int real_ncpus = 1;

static uint8_t kernel_stack[65536] __attribute__((aligned(16)));
static struct real_gate64 master_idt64[256] __attribute__((aligned(16)));
static int idt_ready;

extern uint64_t idt64_stubs[32];
extern uint64_t idt64_syscall_stubs[3];
extern uint64_t idt64_interrupt_stubs[];
extern void gdt_load(struct pseudo_descriptor *);

void cpu_data_set_gs(cpu_data_t *cdp) {
  cdp->cpu_this = cdp;
  uint64_t p = (uint64_t)cdp;
  __asm__ volatile("wrmsr" ::"c"(0xc0000101), "a"((uint32_t)p), "d"((uint32_t)(p >> 32)));
}

void set_kernel_stack(uint64_t top) { current_cpu_datap()->cpu_ktss.rsp0 = top; }

uint64_t boot_kernel_stack_top(void) { return (uint64_t)(kernel_stack + sizeof kernel_stack); }

static struct real_gate64 gate(uint64_t at, uint8_t access, uint8_t ist) {
  return (struct real_gate64){
      .offset_low16 = (uint16_t)at,
      .selector16 = KERNEL64_CS,
      .ist = ist,
      .access = access,
      .offset_high16 = (uint16_t)(at >> 16),
      .offset_top32 = (uint32_t)(at >> 32),
  };
}

static void idt_init(void) {
  for (int v = 0; v < 32; v++) master_idt64[v] = gate(idt64_stubs[v], (v == 3 || v == 4) ? 0xee : 0x8e, v == 8);
  for (int i = 0; i < 3; i++) master_idt64[0x80 + i] = gate(idt64_syscall_stubs[i], 0xee, 0);
  for (uint64_t *e = idt64_interrupt_stubs; e[1]; e += 2) master_idt64[e[0]] = gate(e[1], 0x8e, 0);
  idt_ready = 1;
}

void mp_desc_init(cpu_data_t *cdp) {
  uint64_t *gdt = cdp->cpu_gdt;
  struct x86_64_tss *ktss = &cdp->cpu_ktss;
  gdt[0] = 0;
  gdt[1] = 0x00209a0000000000ull;
  gdt[2] = 0x0000920000000000ull;
  uint64_t tss = (uint64_t)ktss;
  uint64_t limit = sizeof *ktss - 1;
  gdt[3] = (limit & 0xffff) | ((tss & 0xffffff) << 16) | (0x89ull << 40) | (((tss >> 24) & 0xff) << 56);
  gdt[4] = tss >> 32;
  gdt[5] = 0x0000f20000000000ull;
  gdt[6] = 0x0020fa0000000000ull;
  if (!ktss->rsp0) ktss->rsp0 = (uint64_t)(kernel_stack + sizeof kernel_stack);
  ktss->ist1 = (uint64_t)(cdp->cpu_df_stack + sizeof cdp->cpu_df_stack);
  ktss->io_bit_map_offset = sizeof *ktss;

  struct pseudo_descriptor gdtr = {sizeof cdp->cpu_gdt - 1, (uint64_t)gdt};
  gdt_load(&gdtr);
  cpu_data_set_gs(cdp);
  __asm__ volatile("wrmsr" ::"c"(0xc0000103), "a"((uint32_t)cdp->cpu_number), "d"(0));
  __asm__ volatile("ltr %w0" ::"r"(KERNEL_TSS));

  if (!idt_ready) idt_init();
  struct pseudo_descriptor idtr = {sizeof master_idt64 - 1, (uint64_t)master_idt64};
  __asm__ volatile("lidt %0" ::"m"(idtr));
}
