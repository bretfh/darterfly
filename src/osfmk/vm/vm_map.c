#include "vm.h"
#include "../../pexpert/i386/pexpert.h"

#define MAX_ENTRIES 1024
#define USER_MMAP_BASE 0x0000200000000000ull

typedef struct { uint64_t start, end; int prot; } vm_map_entry;

static vm_map_entry entries[MAX_ENTRIES];
static int nentries;
static uint64_t mmap_next = USER_MMAP_BASE;

static void insert_at(int i, uint64_t start, uint64_t end, int prot) {
  if (nentries == MAX_ENTRIES) panic("vm_map: out of entries");
  for (int j = nentries; j > i; j--) entries[j] = entries[j - 1];
  entries[i] = (vm_map_entry){start, end, prot};
  nentries++;
}

static void delete_at(int i) {
  for (int j = i; j < nentries - 1; j++) entries[j] = entries[j + 1];
  nentries--;
}

static void clip(uint64_t at) {
  for (int i = 0; i < nentries; i++)
    if (entries[i].start < at && at < entries[i].end) {
      insert_at(i + 1, at, entries[i].end, entries[i].prot);
      entries[i].end = at;
      return;
    }
}

static uint64_t page_down(uint64_t a) { return a & ~(PAGE_SIZE - 1); }
static uint64_t page_up(uint64_t a) { return (a + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1); }

void vm_map_remove(uint64_t start, uint64_t len) {
  uint64_t s = page_down(start), e = page_up(start + len);
  clip(s);
  clip(e);
  for (int i = 0; i < nentries;)
    if (entries[i].start >= s && entries[i].end <= e) {
      pmap_remove(entries[i].start, entries[i].end - entries[i].start);
      delete_at(i);
    } else
      i++;
}

void vm_map_reset(uint64_t keep, uint64_t len) {
  uint64_t s = page_down(keep), e = page_up(keep + len);
  clip(s);
  clip(e);
  for (int i = 0; i < nentries;)
    if ((entries[i].start >= s && entries[i].end <= e) || entries[i].start >= 0x0000800000000000ull) i++;
    else {
      pmap_remove(entries[i].start, entries[i].end - entries[i].start);
      delete_at(i);
    }
}

int vm_map_enter(uint64_t start, uint64_t len, int prot) {
  uint64_t s = page_down(start), e = page_up(start + len);
  vm_map_remove(s, e - s);
  int i = 0;
  while (i < nentries && entries[i].start < s) i++;
  insert_at(i, s, e, prot);
  return 1;
}

void vm_map_protect(uint64_t start, uint64_t len, int prot) {
  uint64_t s = page_down(start), e = page_up(start + len);
  clip(s);
  clip(e);
  for (int i = 0; i < nentries; i++)
    if (entries[i].start >= s && entries[i].end <= e) entries[i].prot = prot;
  pmap_protect(s, e - s, prot);
}

uint64_t vm_map_find_space(uint64_t len) {
  uint64_t at = mmap_next;
  mmap_next += page_up(len) + PAGE_SIZE;
  return at;
}

static vm_map_entry *lookup(uint64_t va) {
  for (int i = 0; i < nentries; i++)
    if (entries[i].start <= va && va < entries[i].end) return &entries[i];
  return 0;
}

int vm_fault(uint64_t va, uint64_t err) {
  if (pmap_access_ok(page_down(va), err)) return 1;
  vm_map_entry *entry = lookup(va);
  if (!entry || (err & 1) || !entry->prot) return 0;
  if ((err & 2) && !(entry->prot & VM_PROT_WRITE)) return 0;
  if ((err & 0x10) && !(entry->prot & VM_PROT_EXECUTE)) return 0;
  if (pmap_find_phys(va)) return 0;
  uint64_t pa = vm_page_grab();
  if (!pa) return 0;
  uint64_t *page = PHYSMAP_PTOV(pa);
  for (int j = 0; j < 512; j++) page[j] = 0;
  pmap_enter(page_down(va), pa, entry->prot);
  return 1;
}

#define IO_MAP_BASE 0xfffffe0000000000ull

static uint64_t io_map(uint64_t pa, uint64_t size, int wcomb) {
  static uint64_t next = IO_MAP_BASE;
  uint64_t offset = pa & (PAGE_SIZE - 1), base = page_down(pa), len = page_up(size + offset);
  uint64_t va = next;
  next += len;
  for (uint64_t off = 0; off < len; off += PAGE_SIZE) pmap_enter_io(va + off, base + off, wcomb);
  return va + offset;
}

uint64_t ml_io_map(uint64_t pa, uint64_t size) { return io_map(pa, size, 0); }
uint64_t ml_io_map_wcomb(uint64_t pa, uint64_t size) { return io_map(pa, size, 1); }
