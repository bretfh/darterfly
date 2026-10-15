#include "../../pexpert/i386/pexpert.h"
#include "seg.h"
#include "../vm/vm.h"
#include "cpu_data.h"

typedef struct {
  uint32_t Type;
  uint64_t PhysicalStart, VirtualStart, NumberOfPages, Attribute;
} EfiMemoryRange;

boot_args *PE_boot_args;

static int usable(uint32_t type) {
  return type == 1 || type == 2 || type == 3 || type == 4 || type == 7;
}

static void vm_test(void) {
  uint64_t base = 0x1200000000ull, len = 1ull << 30;
  uint64_t before = vm_page_free_count();
  vm_map_enter(base, len, VM_PROT_READ | VM_PROT_WRITE);
  uint64_t sum = 0;
  for (uint64_t a = base; a < base + len; a += 2ull << 20) {
    if (*(volatile uint64_t *)a != 0) panic("vmtest: page at 0x%lx is not zero", a);
    *(volatile uint64_t *)a = a;
  }
  for (uint64_t a = base; a < base + len; a += 2ull << 20) sum += *(volatile uint64_t *)a == a;
  kprintf("vmtest: %lu demand-zero pages, %lu read back, %lu pages taken\n", len / (2ull << 20), sum,
          before - vm_page_free_count());
  void *a = kalloc(100), *b = kalloc(100000);
  kfree(a);
  void *c = kalloc(90);
  kprintf("vmtest: kalloc %s\n", a == c && b ? "reuses freed blocks" : "is wrong");
}

#define USER_STACK_TOP 0x00007ff000000000ull
#define USER_STACK_SIZE (8ull << 20)

void rtclock_init(void);
void lapic_init(void);
extern void _libsa_start(const char *cmdline);

uint64_t boot_kernel_stack_top(void);
#include "../kern/thread.h"
#include "../../bsd/kern/kern_sig.h"

uint64_t restart_core, restart_core_size;

typedef struct {
  uint32_t p_type, p_flags;
  uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
} elf_phdr;

static void reset_user_image(void) {
  uint8_t *file = PHYSMAP_PTOV(PE_boot_args->kernelFileStart);
  uint64_t phoff = *(uint64_t *)(file + 32);
  uint16_t phnum = *(uint16_t *)(file + 56);
  elf_phdr *ph = (elf_phdr *)(file + phoff);
  for (int i = 0; i < phnum; i++)
    if (ph[i].p_type == 1 && (ph[i].p_flags & 2) && ph[i].p_vaddr < 0xffff800000000000ull) {
      uint8_t *to = (uint8_t *)ph[i].p_vaddr;
      for (uint64_t k = 0; k < ph[i].p_filesz; k++) to[k] = file[ph[i].p_offset + k];
      for (uint64_t k = ph[i].p_filesz; k < ph[i].p_memsz; k++) to[k] = 0;
    }
}

void load_init_program(void);

int restart_user(uint64_t core, uint64_t size) {
  thread_t self = current_thread();
  for (thread_t t = all_threads; t; t = t->all_next)
    if (t != self && t->state != TH_TERMINATE) return 0;
  vm_map_reset(core, size);
  reset_user_image();
  restart_core = core;
  restart_core_size = size;
  self->sigmask = self->siglist = 0;
  p_siglist = 0;
  kprintf("restart: core 0x%lx size %lu\n", core, size);
  load_init_program();
  return 1;
}

void load_init_program(void) {
  vm_map_enter(USER_STACK_TOP - USER_STACK_SIZE, USER_STACK_SIZE, VM_PROT_READ | VM_PROT_WRITE);
  kprintf("load_init_program: sbcl\n");
  uint64_t entry;
  __asm__("movabs $_libsa_start, %0" : "=r"(entry));
  funnel_unlock();
  thread_bootstrap_return(entry, USER_STACK_TOP - 72, (uint64_t)PE_boot_args->CommandLine);
}

void i386_init(boot_args *args) {
  cpu_data_set_gs(cpu_datap(0));
  funnel_lock();
  PE_boot_args = args;
  serial_init();
  kprintf("finch Kernel Version 0.1: %s; root:finch/RELEASE_X86_64\n", BUILD_DATE);
  kprintf("boot_args: Revision %u Version %u efiMode %u\n", args->Revision, args->Version, args->efiMode);
  kprintf("boot-args: %s\n", args->CommandLine);
  kprintf("kernel: 0x%x size %u kslide 0x%x\n", args->kaddr, args->ksize, args->kslide);
  uint64_t pages = 0;
  uint32_t ranges = args->MemoryMapSize / args->MemoryMapDescriptorSize;
  for (uint32_t i = 0; i < ranges; i++) {
    EfiMemoryRange *r = (EfiMemoryRange *)((uint8_t *)(uintptr_t)args->MemoryMap + i * args->MemoryMapDescriptorSize);
    if (usable(r->Type)) pages += r->NumberOfPages;
  }
  kprintf("memory: %u ranges, %lu MB usable\n", ranges, pages * 4096 / (1024 * 1024));
  kprintf("video: %ux%ux%u at 0x%lx\n", args->Video.v_width, args->Video.v_height, args->Video.v_depth,
          args->Video.v_baseAddr);
  mp_desc_init(cpu_datap(0));
  kprintf("mp_desc: gdt, idt and ktss loaded\n");
  vm_page_bootstrap(args);
  pmap_bootstrap(args);
  args = PHYSMAP_PTOV(args);
  PE_boot_args = args;
  kalloc_init();
  kprintf("vm: %lu MB free\n", vm_page_free_count() * PAGE_SIZE / (1024 * 1024));
  if (PE_parse_boot_arg("vmtest")) vm_test();
  rtclock_init();
  pat_init();
  lapic_init();
  thread_bootstrap(boot_kernel_stack_top());
  i386_start_cpus();
  if (PE_parse_boot_arg("trap")) __asm__ volatile("int3");
  if (PE_parse_boot_arg("halt")) {
    kprintf("halt\n");
    PE_halt();
  }
  load_init_program();
}
