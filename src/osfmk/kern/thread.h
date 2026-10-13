#pragma once
#include <stdint.h>
#include "../i386/seg.h"
#include "../i386/cpu_data.h"

#define TH_RUN 1
#define TH_WAIT 2
#define TH_TERMINATE 4

#define TH_SFLAG_ABORTSAFELY 0x20

#define THREAD_AWAKENED 0
#define THREAD_TIMED_OUT 1
#define THREAD_INTERRUPTED 2

typedef struct thread {
  uint64_t kernel_rsp;
  uint64_t kstack_top;
  uint64_t fs_base;
  uint64_t thread_id;
  int state;
  int sched_flags;
  int wait_result;
  uint64_t wait_event;
  uint64_t wait_deadline;
  uint64_t sigmask, siglist;
  struct thread *runq_next, *all_next;
  uint8_t fpu_state[512] __attribute__((aligned(16)));
} *thread_t;

extern thread_t all_threads;

static inline thread_t current_thread(void) { return current_cpu_datap()->cpu_active_thread; }

thread_t thread_bootstrap(uint64_t kstack_top);
thread_t thread_create_user(uint64_t rip, uint64_t rsp, uint64_t arg, uint64_t fs_base);
void thread_setrun(thread_t t);
void thread_block(void);
int thread_wait(uint64_t event, uint64_t deadline);
int thread_wakeup(uint64_t event, int all);
void thread_wakeup_thread(thread_t t, int result);
void thread_abort_safely(thread_t t);
void thread_terminate_self(void) __attribute__((noreturn));
void sched_tick(void);
void sched_ast(void);
uint64_t rdtsc(void);
