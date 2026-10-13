#include "../../pexpert/i386/pexpert.h"
#include "../vm/vm.h"
#include "thread.h"

thread_t all_threads;

static thread_t runq_head, runq_tail;
static uint64_t next_thread_id = 0x100;

void Switch_context(uint64_t *old_rsp, uint64_t new_rsp);
void return_to_user(void);
void set_kernel_stack(uint64_t top);

uint64_t rdtsc(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
}

static void switch_to(thread_t next);
thread_t idle_thread_create(void);

static void enqueue(thread_t t) {
  t->runq_next = 0;
  if (runq_tail) runq_tail->runq_next = t;
  else runq_head = t;
  runq_tail = t;
}

static thread_t dequeue(void) {
  thread_t t = runq_head;
  if (t) {
    runq_head = t->runq_next;
    if (!runq_head) runq_tail = 0;
  }
  return t;
}

static thread_t thread_alloc_unlisted(void) {
  thread_t t = kalloc(sizeof *t + 16);
  t = (thread_t)(((uint64_t)t + 15) & ~15ull);
  for (unsigned i = 0; i < sizeof *t; i++) ((char *)t)[i] = 0;
  return t;
}

static thread_t thread_alloc(void) {
  thread_t t = thread_alloc_unlisted();
  t->thread_id = next_thread_id++;
  t->all_next = all_threads;
  all_threads = t;
  return t;
}

thread_t thread_bootstrap(uint64_t kstack_top) {
  thread_t t = thread_alloc();
  t->kstack_top = kstack_top;
  t->state = TH_RUN;
  current_cpu_datap()->cpu_active_thread = t;
  current_cpu_datap()->cpu_idle_thread = idle_thread_create();
  return t;
}

#define KERNEL_STACK_SIZE (32 * 1024)

void idle_thread(void) __attribute__((noreturn));
int funnel_depth(void);

thread_t idle_thread_create(void) {
  thread_t t = thread_alloc_unlisted();
  char *stack = kalloc(KERNEL_STACK_SIZE);
  t->kstack_top = ((uint64_t)(stack + KERNEL_STACK_SIZE)) & ~15ull;
  t->state = TH_RUN;
  uint64_t *k = (uint64_t *)t->kstack_top;
  *--k = 0;
  *--k = (uint64_t)idle_thread;
  for (int i = 0; i < 6; i++) *--k = 0;
  t->kernel_rsp = (uint64_t)k;
  return t;
}

void idle_thread(void) {
  cpu_data_t *cdp = current_cpu_datap();
  for (;;) {
    thread_t next = dequeue();
    if (next) {
      switch_to(next);
      continue;
    }
    if (funnel_depth() != 1) panic("idle_thread: funnel depth %d", funnel_depth());
    cdp->cpu_idle = 1;
    funnel_unlock();
    __asm__ volatile("sti; hlt; cli");
    funnel_lock();
    cdp->cpu_idle = 0;
  }
}

thread_t thread_create_user(uint64_t rip, uint64_t rsp, uint64_t arg, uint64_t fs_base) {
  thread_t t = thread_alloc();
  char *stack = kalloc(KERNEL_STACK_SIZE);
  for (int i = 0; i < KERNEL_STACK_SIZE; i++) stack[i] = 0;
  t->kstack_top = (uint64_t)(stack + KERNEL_STACK_SIZE);
  t->fs_base = fs_base;
  t->sigmask = current_thread()->sigmask;
  __asm__ volatile("fxsave64 %0" : "=m"(t->fpu_state));
  x86_saved_state64_t *frame = (x86_saved_state64_t *)(t->kstack_top - sizeof *frame);
  frame->rip = rip;
  frame->cs = USER64_CS;
  frame->rflags = 0x202;
  frame->rsp = rsp;
  frame->ss = USER_DS;
  frame->rdi = arg;
  uint64_t *k = (uint64_t *)frame;
  *--k = (uint64_t)return_to_user;
  for (int i = 0; i < 6; i++) *--k = 0;
  t->kernel_rsp = (uint64_t)k;
  thread_setrun(t);
  return t;
}

void thread_setrun(thread_t t) {
  if (t->state == TH_RUN) return;
  t->state = TH_RUN;
  enqueue(t);
  for (int i = 0; i < real_ncpus; i++) {
    cpu_data_t *cdp = cpu_datap(i);
    if (i != cpu_number() && cdp->cpu_running && cdp->cpu_idle) {
      cdp->cpu_idle = 0;
      i386_signal_cpu(i);
      return;
    }
  }
}

static void switch_to(thread_t next) {
  thread_t old = current_thread();
  if (next == old) return;
  __asm__ volatile("fxsave64 %0" : "=m"(old->fpu_state));
  __asm__ volatile("fxrstor64 %0" ::"m"(next->fpu_state));
  current_cpu_datap()->cpu_active_thread = next;
  set_kernel_stack(next->kstack_top);
  __asm__ volatile("wrmsr" ::"c"(0xc0000100), "a"((uint32_t)next->fs_base), "d"((uint32_t)(next->fs_base >> 32)));
  Switch_context(&old->kernel_rsp, next->kernel_rsp);
}

void thread_block(void) {
  thread_t self = current_thread();
  if (self->state == TH_RUN) enqueue(self);
  thread_t next = dequeue();
  if (!next) next = current_cpu_datap()->cpu_idle_thread;
  if (next == self) return;
  switch_to(next);
}

int thread_wait(uint64_t event, uint64_t deadline) {
  thread_t self = current_thread();
  if (self->sched_flags & TH_SFLAG_ABORTSAFELY) {
    self->sched_flags &= ~TH_SFLAG_ABORTSAFELY;
    return THREAD_INTERRUPTED;
  }
  self->state = TH_WAIT;
  self->wait_event = event;
  self->wait_deadline = deadline;
  self->wait_result = THREAD_AWAKENED;
  thread_block();
  return self->wait_result;
}

void thread_wakeup_thread(thread_t t, int result) {
  if (t->state != TH_WAIT) return;
  t->wait_result = result;
  t->wait_event = 0;
  t->wait_deadline = 0;
  thread_setrun(t);
}

void thread_abort_safely(thread_t t) {
  if (t->state == TH_WAIT) {
    thread_wakeup_thread(t, THREAD_INTERRUPTED);
    return;
  }
  t->sched_flags |= TH_SFLAG_ABORTSAFELY;
  cause_ast_check(t);
}

int thread_wakeup(uint64_t event, int all) {
  int n = 0;
  for (thread_t t = all_threads; t; t = t->all_next)
    if (t->state == TH_WAIT && t->wait_event == event) {
      thread_wakeup_thread(t, THREAD_AWAKENED);
      n++;
      if (!all) break;
    }
  return n;
}

void thread_terminate_self(void) {
  current_thread()->state = TH_TERMINATE;
  thread_block();
  panic("thread_terminate_self: came back");
}

void sched_tick(void) {
  if (cpu_number() == 0) {
    uint64_t now = rdtsc();
    for (thread_t t = all_threads; t; t = t->all_next)
      if (t->state == TH_WAIT && t->wait_deadline && now >= t->wait_deadline)
        thread_wakeup_thread(t, THREAD_TIMED_OUT);
  }
  if (runq_head) current_cpu_datap()->cpu_pending_ast = 1;
}

void sched_ast(void) {
  cpu_data_t *cdp = current_cpu_datap();
  if (!cdp->cpu_pending_ast) return;
  cdp->cpu_pending_ast = 0;
  thread_block();
}
