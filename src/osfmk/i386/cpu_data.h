#pragma once
#include <stdint.h>

#define MAX_CPUS 32

struct __attribute__((packed)) x86_64_tss {
  uint32_t reserved1;
  uint64_t rsp0, rsp1, rsp2;
  uint64_t reserved2;
  uint64_t ist1, ist2, ist3, ist4, ist5, ist6, ist7;
  uint64_t reserved3;
  uint16_t reserved4;
  uint16_t io_bit_map_offset;
};

struct thread;

typedef struct cpu_data {
  struct cpu_data *cpu_this;
  struct thread *cpu_active_thread;
  struct thread *cpu_idle_thread;
  int cpu_number;
  uint32_t cpu_phys_number;
  volatile int cpu_running;
  volatile int cpu_idle;
  volatile int cpu_tlb_invalid;
  int cpu_pending_ast;
  uint64_t cpu_gdt[7] __attribute__((aligned(16)));
  struct x86_64_tss cpu_ktss __attribute__((aligned(16)));
  uint8_t cpu_df_stack[8192] __attribute__((aligned(16)));
} cpu_data_t;

extern cpu_data_t cpu_data_master[MAX_CPUS];
extern int real_ncpus;

static inline cpu_data_t *current_cpu_datap(void) {
  cpu_data_t *p;
  __asm__ volatile("mov %%gs:0, %0" : "=r"(p));
  return p;
}

static inline cpu_data_t *cpu_datap(int cpu) { return &cpu_data_master[cpu]; }
static inline int cpu_number(void) { return current_cpu_datap()->cpu_number; }
static inline void cpu_pause(void) { __asm__ volatile("pause" ::: "memory"); }

void cpu_data_set_gs(cpu_data_t *cdp);
void set_kernel_stack(uint64_t top);
void mp_desc_init(cpu_data_t *cdp);
void funnel_lock(void);
void funnel_unlock(void);
void i386_signal_cpu(int cpu);
void process_pmap_updates(void);
void pmap_flush_tlbs(void);
void i386_start_cpus(void);
void cause_ast_check(struct thread *t);
