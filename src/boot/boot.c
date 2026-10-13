#include "efi.h"
#include "../pexpert/i386/boot.h"

static EFI_SYSTEM_TABLE *ST;
static EFI_BOOT_SERVICES *BS;

void *memset(void *d, int c, size_t n) {
  uint8_t *p = d;
  while (n--) *p++ = (uint8_t)c;
  return d;
}

void *memcpy(void *d, const void *s, size_t n) {
  uint8_t *p = d;
  const uint8_t *q = s;
  while (n--) *p++ = *q++;
  return d;
}

static inline void outb(uint16_t port, uint8_t v) { __asm__ volatile("outb %0, %1" ::"a"(v), "Nd"(port)); }
static inline uint8_t inb(uint16_t port) {
  uint8_t v;
  __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
  return v;
}

static void putc_serial(char c) {
  while (!(inb(0x3f8 + 5) & 0x20)) {}
  outb(0x3f8, (uint8_t)c);
}

static void puts_serial(const char *s) {
  for (; *s; s++) {
    if (*s == '\n') putc_serial('\r');
    putc_serial(*s);
  }
}

static void put_hex(uint64_t v) {
  char b[19] = "0x";
  int n = 2;
  int shift = 60;
  while (shift > 0 && !((v >> shift) & 0xf)) shift -= 4;
  for (; shift >= 0; shift -= 4) b[n++] = "0123456789abcdef"[(v >> shift) & 0xf];
  b[n] = 0;
  puts_serial(b);
}

static void put_dec(uint64_t v) {
  char b[21];
  int n = 20;
  b[n] = 0;
  do b[--n] = (char)('0' + v % 10); while (v /= 10);
  puts_serial(b + n);
}

static void fail(const char *what, EFI_STATUS status) {
  puts_serial("boot.efi: ");
  puts_serial(what);
  puts_serial(" failed: ");
  put_hex(status);
  puts_serial("\n");
  for (;;) __asm__ volatile("hlt");
}

static void *allocate_low(UINTN size) {
  EFI_PHYSICAL_ADDRESS address = 0xffffffff;
  EFI_STATUS s = BS->AllocatePages(AllocateMaxAddress, EfiLoaderData, (size + 4095) / 4096, &address);
  if (EFI_ERROR(s)) fail("AllocatePages", s);
  memset((void *)address, 0, size);
  return (void *)address;
}

static EFI_FILE_PROTOCOL *volume(EFI_HANDLE image) {
  EFI_GUID loaded_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
  EFI_GUID fs_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
  EFI_LOADED_IMAGE_PROTOCOL *loaded;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs;
  EFI_FILE_PROTOCOL *root;
  EFI_STATUS s;
  if (EFI_ERROR(s = BS->HandleProtocol(image, &loaded_guid, (void **)&loaded))) fail("LoadedImage", s);
  if (EFI_ERROR(s = BS->HandleProtocol(loaded->DeviceHandle, &fs_guid, (void **)&fs))) fail("SimpleFileSystem", s);
  if (EFI_ERROR(s = fs->OpenVolume(fs, &root))) fail("OpenVolume", s);
  return root;
}

static void *read_file(EFI_FILE_PROTOCOL *root, CHAR16 *path, UINTN *size) {
  EFI_FILE_PROTOCOL *file;
  uint64_t end;
  void *buffer;
  if (EFI_ERROR(root->Open(root, &file, path, EFI_FILE_MODE_READ, 0))) return 0;
  file->SetPosition(file, 0xffffffffffffffffull);
  file->GetPosition(file, &end);
  file->SetPosition(file, 0);
  *size = end;
  EFI_STATUS s = BS->AllocatePool(EfiLoaderData, end + 1, &buffer);
  if (EFI_ERROR(s)) fail("AllocatePool", s);
  if (EFI_ERROR(s = file->Read(file, size, buffer))) fail("Read", s);
  ((char *)buffer)[*size] = 0;
  file->Close(file);
  return buffer;
}

static const char *find(const char *hay, const char *needle) {
  for (; *hay; hay++) {
    const char *h = hay, *n = needle;
    while (*n && *h == *n) h++, n++;
    if (!*n) return hay;
  }
  return 0;
}

static void kernel_flags(EFI_FILE_PROTOCOL *root, boot_args *args) {
  UINTN size;
  const char *plist = read_file(root, L"\\Library\\Preferences\\SystemConfiguration\\com.apple.Boot.plist", &size);
  const char *at;
  if (!plist || !(at = find(plist, "<key>Kernel Flags</key>")) || !(at = find(at, "<string>"))) return;
  at += 8;
  for (int i = 0; i < BOOT_LINE_LENGTH - 1 && *at && *at != '<'; i++) args->CommandLine[i] = *at++;
}

typedef struct {
  uint8_t e_ident[16];
  uint16_t e_type, e_machine;
  uint32_t e_version;
  uint64_t e_entry, e_phoff, e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} Elf64_Ehdr;

typedef struct {
  uint32_t p_type, p_flags;
  uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
} Elf64_Phdr;

typedef struct {
  int64_t d_tag;
  uint64_t d_val;
} Elf64_Dyn;

typedef struct {
  uint64_t r_offset, r_info;
  int64_t r_addend;
} Elf64_Rela;

static uint64_t load_kernel(EFI_FILE_PROTOCOL *root, boot_args *args) {
  UINTN size;
  uint8_t *image = read_file(root, L"\\System\\Library\\Kernels\\kernel", &size);
  if (!image) fail("kernel", 0);
  Elf64_Ehdr *eh = (Elf64_Ehdr *)image;
  if (eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' || eh->e_machine != 62) fail("kernel is not x86_64 ELF", 0);
  Elf64_Phdr *ph = (Elf64_Phdr *)(image + eh->e_phoff);
  uint64_t span = 0;
  for (int i = 0; i < eh->e_phnum; i++)
    if (ph[i].p_type == 1 && ph[i].p_vaddr + ph[i].p_memsz > span) span = ph[i].p_vaddr + ph[i].p_memsz;
  span = (span + 4095) & ~4095ull;
  uint8_t *base = allocate_low(span);
  Elf64_Dyn *dynamic = 0;
  for (int i = 0; i < eh->e_phnum; i++) {
    if (ph[i].p_type == 1) memcpy(base + ph[i].p_vaddr, image + ph[i].p_offset, ph[i].p_filesz);
    if (ph[i].p_type == 2) dynamic = (Elf64_Dyn *)(base + ph[i].p_vaddr);
  }
  uint64_t rela = 0, relasz = 0;
  for (; dynamic && dynamic->d_tag; dynamic++) {
    if (dynamic->d_tag == 7) rela = dynamic->d_val;
    if (dynamic->d_tag == 8) relasz = dynamic->d_val;
  }
  for (Elf64_Rela *r = (Elf64_Rela *)(base + rela); (uint8_t *)r < base + rela + relasz; r++) {
    if ((r->r_info & 0xffffffff) != 8) fail("kernel relocation type", r->r_info);
    *(uint64_t *)(base + r->r_offset) = (uint64_t)base + r->r_addend;
  }
  args->kaddr = (uint32_t)(uintptr_t)base;
  args->ksize = (uint32_t)span;
  args->kslide = (uint32_t)(uintptr_t)base;
  return (uint64_t)base + eh->e_entry;
}

static void video(boot_args *args) {
  EFI_GUID gop_guid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop;
  if (EFI_ERROR(BS->LocateProtocol(&gop_guid, 0, (void **)&gop))) return;
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *m = gop->Mode;
  args->Video.v_display = GRAPHICS_MODE;
  args->Video.v_rowBytes = m->Info->PixelsPerScanLine * 4;
  args->Video.v_width = m->Info->HorizontalResolution;
  args->Video.v_height = m->Info->VerticalResolution;
  args->Video.v_depth = 32;
  args->Video.v_baseAddr = m->FrameBufferBase;
  args->VideoV1.v_baseAddr = (uint32_t)m->FrameBufferBase;
  args->VideoV1.v_display = GRAPHICS_MODE;
  args->VideoV1.v_rowBytes = args->Video.v_rowBytes;
  args->VideoV1.v_width = args->Video.v_width;
  args->VideoV1.v_height = args->Video.v_height;
  args->VideoV1.v_depth = 32;
}

static int guid_equal(EFI_GUID *a, EFI_GUID *b) {
  const uint8_t *p = (const uint8_t *)a, *q = (const uint8_t *)b;
  for (int i = 0; i < 16; i++)
    if (p[i] != q[i]) return 0;
  return 1;
}

static void *rsdp(void) {
  EFI_GUID acpi = EFI_ACPI_20_TABLE_GUID;
  for (UINTN i = 0; i < ST->NumberOfTableEntries; i++)
    if (guid_equal(&ST->ConfigurationTable[i].VendorGuid, &acpi)) return ST->ConfigurationTable[i].VendorTable;
  return 0;
}

typedef void __attribute__((sysv_abi, noreturn)) (*kernel_entry)(boot_args *);

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *system_table) {
  ST = system_table;
  BS = ST->BootServices;
  BS->SetWatchdogTimer(0, 0, 0, 0);
  puts_serial("\nfinch boot.efi\n");

  boot_args *args = allocate_low(sizeof(boot_args));
  args->Revision = kBootArgsRevision;
  args->Version = kBootArgsVersion;
  args->efiMode = kBootArgsEfiMode64;
  args->efiSystemTable = (uint32_t)(uintptr_t)ST;

  EFI_FILE_PROTOCOL *root = volume(image);
  kernel_flags(root, args);
  uint64_t entry = load_kernel(root, args);
  video(args);

  puts_serial("boot.efi: kernel ");
  put_hex(args->kaddr);
  puts_serial(" size ");
  put_dec(args->ksize);
  puts_serial(" entry ");
  put_hex(entry);
  puts_serial("\nboot.efi: video ");
  put_dec(args->Video.v_width);
  puts_serial("x");
  put_dec(args->Video.v_height);
  puts_serial(" at ");
  put_hex(args->Video.v_baseAddr);
  puts_serial("\nboot.efi: rsdp ");
  put_hex((uint64_t)rsdp());
  puts_serial("\nboot.efi: boot-args \"");
  puts_serial(args->CommandLine);
  puts_serial("\"\n");

  UINTN size = 0, key, descriptor_size;
  uint32_t descriptor_version;
  BS->GetMemoryMap(&size, 0, &key, &descriptor_size, &descriptor_version);
  UINTN capacity = size + 16 * descriptor_size;
  EFI_MEMORY_DESCRIPTOR *map = allocate_low(capacity);
  EFI_STATUS s;
  for (int tries = 0;; tries++) {
    size = capacity;
    if (EFI_ERROR(s = BS->GetMemoryMap(&size, map, &key, &descriptor_size, &descriptor_version)))
      fail("GetMemoryMap", s);
    if (!EFI_ERROR(s = BS->ExitBootServices(image, key))) break;
    if (tries == 3) fail("ExitBootServices", s);
  }
  args->MemoryMap = (uint32_t)(uintptr_t)map;
  args->MemoryMapSize = (uint32_t)size;
  args->MemoryMapDescriptorSize = (uint32_t)descriptor_size;
  args->MemoryMapDescriptorVersion = descriptor_version;

  __asm__ volatile("cli");
  ((kernel_entry)entry)(args);
}
