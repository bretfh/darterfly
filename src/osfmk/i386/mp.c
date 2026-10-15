#include "../../pexpert/i386/pexpert.h"
#include "../../boot/efi.h"
#include "../vm/vm.h"
#include "../kern/thread.h"
#include "seg.h"
#include "cpu_data.h"

extern boot_args *PE_boot_args;
extern struct { uint64_t tsc_hz, tsc_base, epoch_base; } commpage;
extern char slave_boot_base[], slave_boot_end[], slave_cr3[], slave_rsp[], slave_cpu[], slave_entry[];

uint32_t lapic_id(void);
void lapic_send_ipi(uint32_t apic_id, uint32_t icr);
void lapic_init_slave(void);
thread_t idle_thread_create(void);
void idle_thread(void) __attribute__((noreturn));

static struct {
  volatile int owner;
  int depth;
} kernel_flock = {-1, 0};

void funnel_lock(void) {
  int me = cpu_number();
  if (kernel_flock.owner == me) {
    kernel_flock.depth++;
    return;
  }
  int free = -1;
  while (!__atomic_compare_exchange_n(&kernel_flock.owner, &free, me, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
    free = -1;
    process_pmap_updates();
    cpu_pause();
  }
  kernel_flock.depth = 1;
}

void funnel_unlock(void) {
  if (kernel_flock.owner != cpu_number()) panic("funnel_unlock: cpu %d does not hold the funnel", cpu_number());
  if (--kernel_flock.depth == 0) __atomic_store_n(&kernel_flock.owner, -1, __ATOMIC_RELEASE);
}

int funnel_depth(void) { return kernel_flock.owner == cpu_number() ? kernel_flock.depth : 0; }

void process_pmap_updates(void) {
  cpu_data_t *cdp = current_cpu_datap();
  if (!cdp->cpu_tlb_invalid) return;
  uint64_t cr3;
  __asm__ volatile("mov %%cr3, %0; mov %0, %%cr3" : "=r"(cr3)::"memory");
  __atomic_store_n(&cdp->cpu_tlb_invalid, 0, __ATOMIC_RELEASE);
}

void pmap_flush_tlbs(void) {
  int me = cpu_number(), any = 0;
  for (int i = 0; i < real_ncpus; i++)
    if (i != me && cpu_datap(i)->cpu_running) {
      __atomic_store_n(&cpu_datap(i)->cpu_tlb_invalid, 1, __ATOMIC_RELEASE);
      any = 1;
    }
  if (!any) return;
  for (int i = 0; i < real_ncpus; i++)
    if (cpu_datap(i)->cpu_tlb_invalid) i386_signal_cpu(i);
  for (int i = 0; i < real_ncpus; i++)
    while (cpu_datap(i)->cpu_tlb_invalid) cpu_pause();
}

void cause_ast_check(thread_t t) {
  for (int i = 0; i < real_ncpus; i++)
    if (i != cpu_number() && cpu_datap(i)->cpu_active_thread == t) {
      i386_signal_cpu(i);
      return;
    }
}

struct __attribute__((packed)) acpi_header {
  char signature[4];
  uint32_t length;
  uint8_t revision, checksum;
  char oem[6], oem_table[8];
  uint32_t oem_revision, creator, creator_revision;
};

static int sig_equal(const char *a, const char *b, int n) {
  for (int i = 0; i < n; i++)
    if (a[i] != b[i]) return 0;
  return 1;
}

static struct acpi_header *acpi_find(const char *signature) {
  EFI_SYSTEM_TABLE *st = PHYSMAP_PTOV(PE_boot_args->efiSystemTable);
  EFI_CONFIGURATION_TABLE *ct = PHYSMAP_PTOV(st->ConfigurationTable);
  EFI_GUID acpi = EFI_ACPI_20_TABLE_GUID;
  uint8_t *rsdp = 0;
  for (UINTN i = 0; i < st->NumberOfTableEntries; i++)
    if (sig_equal((char *)&ct[i].VendorGuid, (char *)&acpi, sizeof acpi)) rsdp = PHYSMAP_PTOV(ct[i].VendorTable);
  if (!rsdp) return 0;
  struct acpi_header *xsdt = PHYSMAP_PTOV(*(uint64_t *)(rsdp + 24));
  uint64_t *entries = (uint64_t *)(xsdt + 1);
  for (uint32_t i = 0; i < (xsdt->length - sizeof *xsdt) / 8; i++) {
    struct acpi_header *h = PHYSMAP_PTOV(entries[i]);
    if (sig_equal(h->signature, signature, 4)) return h;
  }
  return 0;
}

static uint32_t madt_cpus(uint32_t *ids) {
  struct acpi_header *madt = acpi_find("APIC");
  if (!madt) return 0;
  uint32_t n = 0;
  uint8_t *p = (uint8_t *)madt + 44, *end = (uint8_t *)madt + madt->length;
  while (p < end && p[1]) {
    if (p[0] == 0 && (*(uint32_t *)(p + 4) & 1) && n < MAX_CPUS) ids[n++] = p[3];
    p += p[1];
  }
  return n;
}

typedef struct {
  uint32_t Type;
  uint64_t PhysicalStart, VirtualStart, NumberOfPages, Attribute;
} EfiMemoryRange;

static uint64_t slave_boot_page(void) {
  boot_args *args = PE_boot_args;
  uint32_t n = args->MemoryMapSize / args->MemoryMapDescriptorSize;
  for (uint32_t i = 0; i < n; i++) {
    EfiMemoryRange *r = PHYSMAP_PTOV((uint64_t)args->MemoryMap + i * args->MemoryMapDescriptorSize);
    if (r->Type != 7) continue;
    uint64_t start = r->PhysicalStart < 0x1000 ? 0x1000 : r->PhysicalStart;
    uint64_t end = r->PhysicalStart + r->NumberOfPages * PAGE_SIZE;
    if (end > 0x9f000) end = 0x9f000;
    if (start + 4 * PAGE_SIZE <= end) return start;
  }
  return 0;
}

static void delay_us(uint64_t us) {
  uint64_t end = rdtsc() + us * (commpage.tsc_hz / 1000000);
  while (rdtsc() < end) cpu_pause();
}

static uint64_t bsp_cr0, bsp_cr3, bsp_cr4;

void i386_init_slave(cpu_data_t *cdp) {
  __asm__ volatile("mov %0, %%cr3" ::"r"(bsp_cr3) : "memory");
  __asm__ volatile("mov %0, %%cr4" ::"r"(bsp_cr4));
  __asm__ volatile("mov %0, %%cr0" ::"r"(bsp_cr0));
  __asm__ volatile("fninit");
  mp_desc_init(cdp);
  cdp->cpu_active_thread = cdp->cpu_idle_thread;
  set_kernel_stack(cdp->cpu_idle_thread->kstack_top);
  pat_init();
  lapic_init_slave();
  __atomic_store_n(&cdp->cpu_running, 1, __ATOMIC_RELEASE);
  funnel_lock();
  idle_thread();
}

static int start_cpu(int cpu, uint64_t page) {
  cpu_data_t *cdp = cpu_datap(cpu);
  uint8_t *code = PHYSMAP_PTOV(page);
  *(uint32_t *)(code + (slave_cr3 - slave_boot_base)) = (uint32_t)(page + PAGE_SIZE);
  *(uint64_t *)(code + (slave_rsp - slave_boot_base)) = cdp->cpu_idle_thread->kstack_top;
  *(uint64_t *)(code + (slave_cpu - slave_boot_base)) = (uint64_t)cdp;
  *(uint64_t *)(code + (slave_entry - slave_boot_base)) = (uint64_t)i386_init_slave;
  lapic_send_ipi(cdp->cpu_phys_number, 0x4500);
  delay_us(10000);
  for (int i = 0; i < 2 && !cdp->cpu_running; i++) {
    lapic_send_ipi(cdp->cpu_phys_number, 0x4600 | (uint32_t)(page >> 12));
    delay_us(200);
  }
  for (int i = 0; i < 1000 && !cdp->cpu_running; i++) delay_us(100);
  return cdp->cpu_running;
}

void i386_start_cpus(void) {
  cpu_data_t *bsp = cpu_datap(0);
  bsp->cpu_phys_number = lapic_id();
  bsp->cpu_running = 1;
  uint32_t ids[MAX_CPUS];
  uint32_t n = madt_cpus(ids);
  uint64_t page = slave_boot_page();
  int limit;
  if (PE_parse_boot_argn("cpus", &limit) && limit > 0 && (uint32_t)limit < n) n = limit;
  if (n <= 1) {
    kprintf("mp: 1 cpu\n");
    return;
  }
  if (!page) panic("mp: no page below 1 MB for the slave boot code");
  __asm__ volatile("mov %%cr0, %0; mov %%cr3, %1; mov %%cr4, %2" : "=r"(bsp_cr0), "=r"(bsp_cr3), "=r"(bsp_cr4));
  uint8_t *code = PHYSMAP_PTOV(page);
  for (uint64_t i = 0; i < (uint64_t)(slave_boot_end - slave_boot_base); i++) code[i] = slave_boot_base[i];
  uint64_t *pml4 = PHYSMAP_PTOV(page + PAGE_SIZE), *pdpt = PHYSMAP_PTOV(page + 2 * PAGE_SIZE),
           *pd = PHYSMAP_PTOV(page + 3 * PAGE_SIZE), *kernel_pml4 = PHYSMAP_PTOV(bsp_cr3 & ~0xfffull);
  for (int i = 0; i < 512; i++) {
    pml4[i] = kernel_pml4[i];
    pdpt[i] = 0;
    pd[i] = 0;
  }
  pml4[0] = (page + 2 * PAGE_SIZE) | 3;
  pdpt[0] = (page + 3 * PAGE_SIZE) | 3;
  pd[0] = 0x83;
  int started = 1;
  for (uint32_t i = 0; i < n; i++) {
    if (ids[i] == bsp->cpu_phys_number) continue;
    cpu_data_t *cdp = cpu_datap(started);
    cdp->cpu_number = started;
    cdp->cpu_phys_number = ids[i];
    cdp->cpu_idle_thread = idle_thread_create();
    cdp->cpu_ktss.rsp0 = cdp->cpu_idle_thread->kstack_top;
    real_ncpus = started + 1;
    if (!start_cpu(started, page)) {
      kprintf("mp: cpu with apic id %u did not start\n", ids[i]);
      real_ncpus = started;
      continue;
    }
    started++;
  }
  kprintf("mp: %d cpus, slave boot code at 0x%lx\n", real_ncpus, page);
}
