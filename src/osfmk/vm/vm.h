#pragma once
#include <stdint.h>
#include <stddef.h>
#include "../../pexpert/i386/boot.h"

#define PAGE_SIZE 4096ull
#define PHYSMAP_BASE 0xffff800000000000ull
#define PHYSMAP_PTOV(pa) ((void *)((uint64_t)(pa) + PHYSMAP_BASE))
#define KERNEL_BASE 0xffffffff80000000ull
extern uint64_t kernel_phys;
#define kvtophys(va) ((uint64_t)(va) - KERNEL_BASE + kernel_phys)

#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define VM_PROT_EXECUTE 4

void vm_page_bootstrap(boot_args *args);
uint64_t vm_page_grab(void);
void vm_page_free(uint64_t pa);
uint64_t vm_page_free_count(void);

void pmap_bootstrap(boot_args *args);
void pmap_enter(uint64_t va, uint64_t pa, int prot);
void pmap_protect(uint64_t va, uint64_t len, int prot);
void pmap_remove(uint64_t va, uint64_t len);
uint64_t pmap_find_phys(uint64_t va);
int pmap_access_ok(uint64_t va, uint64_t err);

int vm_map_enter(uint64_t start, uint64_t len, int prot);
void vm_map_remove(uint64_t start, uint64_t len);
void vm_map_protect(uint64_t start, uint64_t len, int prot);
uint64_t vm_map_find_space(uint64_t len);
int vm_fault(uint64_t va, uint64_t err);

void kalloc_init(void);
void *kalloc(size_t size);
void kfree(void *p);
