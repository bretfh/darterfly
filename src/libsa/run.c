#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include "libsa.h"

#define RUN_MAGIC 0x4e555248434e4946ull
#define RUN_OUT_BASE 0x0000380000000000ul
#define RUN_OUT_SPACE (8ul << 30)
#define RUN_FDS 256
#define RUN_FD_BASE 3
#define RUN_CHUNK 16384

enum {
  VFS_open = 1, VFS_close, VFS_read, VFS_write, VFS_pread, VFS_pwrite, VFS_lseek, VFS_stat, VFS_lstat, VFS_fstat,
  VFS_readlink, VFS_symlink, VFS_mkdir, VFS_rmdir, VFS_unlink, VFS_rename, VFS_chdir, VFS_fchdir, VFS_getcwd,
  VFS_realpath, VFS_chmod, VFS_fchmod, VFS_chown, VFS_fchown, VFS_truncate, VFS_ftruncate, VFS_dup, VFS_dup2,
  VFS_fcntl, VFS_readdir, VFS_link, VFS_utimes, VFS_fsync, VFS_umask, VFS_pipe, VFS_spawn, VFS_waitpid
};

enum { ARG_INT, ARG_STRING, ARG_IN, ARG_OUT };
enum { TAG_CALL = 1, TAG_EXIT, TAG_FILES };

#define PORT_MESSAGE 65536
#define PORT_HEADER 72
#define PORT_CHUNK 49152

struct record {
  uint64_t magic, core, core_size, argv, argv_size, archive, archive_size, cwd, stdin_path, back_core, back_size,
    result, exit_code, port, disk;
};

struct node { char *path; char *data; size_t size, cap; uint32_t mode; int64_t mtime; int dead, written; uint64_t ino; };
struct entry { char *name; unsigned char type; };
struct ofile { int open, flags; struct node *node; size_t off; struct entry *entries; size_t nentries; };

static struct record *record;
static struct node **nodes;
static size_t nnodes, cap_nodes;
static struct ofile fds[RUN_FDS];
static char cwd[1024] = "/";
static int stdin_fd = -1;

static uint64_t hex(const char *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = v * 16 + (p[i] <= '9' ? p[i] - '0' : (p[i] | 32) - 'a' + 10);
  return v;
}

static size_t pad4(size_t n) { return (n + 3) & ~(size_t)3; }

static void normalize(const char *in, char *out) {
  char tmp[2048];
  if (in[0] == '/') strncpy(tmp, in, sizeof tmp - 1);
  else {
    strncpy(tmp, cwd, sizeof tmp - 1);
    strncat(tmp, "/", sizeof tmp - strlen(tmp) - 1);
    strncat(tmp, in, sizeof tmp - strlen(tmp) - 1);
  }
  tmp[sizeof tmp - 1] = 0;
  size_t n = 0;
  out[0] = 0;
  for (char *part = strtok(tmp, "/"); part; part = strtok(0, "/")) {
    if (!strcmp(part, ".")) continue;
    if (!strcmp(part, "..")) {
      while (n && out[n - 1] != '/') n--;
      if (n) n--;
      out[n] = 0;
      continue;
    }
    out[n++] = '/';
    strcpy(out + n, part);
    n += strlen(part);
  }
  if (!n) strcpy(out, "/");
}

static struct node *find(const char *path) {
  for (size_t i = nnodes; i-- > 0;)
    if (!strcmp(nodes[i]->path, path)) return nodes[i]->dead ? 0 : nodes[i];
  return 0;
}

static struct node *add(const char *path, uint32_t mode) {
  if (nnodes == cap_nodes) {
    cap_nodes = cap_nodes ? cap_nodes * 2 : 1024;
    nodes = realloc(nodes, cap_nodes * sizeof *nodes);
  }
  struct node *n = calloc(1, sizeof *n);
  nodes[nnodes++] = n;
  n->ino = nnodes + 1;
  n->path = strdup(path);
  n->mode = mode;
  return n;
}

static int is_dir(const char *path) {
  struct node *n = find(path);
  if (n) return (n->mode & S_IFMT) == S_IFDIR;
  if (!strcmp(path, "/")) return 1;
  size_t len = strlen(path);
  for (size_t i = 0; i < nnodes; i++)
    if (!nodes[i]->dead && !strncmp(nodes[i]->path, path, len) && nodes[i]->path[len] == '/') return 1;
  return 0;
}

static void load_archive(const char *p, size_t size) {
  const char *end = p + size;
  while (p + 110 <= end && !memcmp(p, "070701", 6)) {
    uint32_t mode = (uint32_t)hex(p + 14);
    int64_t mtime = (int64_t)hex(p + 46);
    size_t filesize = hex(p + 54), namesize = hex(p + 94);
    const char *name = p + 110;
    if (!strcmp(name, "TRAILER!!!")) break;
    const char *data = p + pad4(110 + namesize);
    char path[2048];
    normalize(name, path);
    struct node *n = add(path, mode ? mode : S_IFREG | 0644);
    n->data = (char *)data;
    n->size = filesize;
    n->mtime = mtime;
    p = data + pad4(filesize);
  }
}

static void own(struct node *n) {
  if (n->written) return;
  char *copy = malloc(n->size ? n->size : 1);
  memcpy(copy, n->data, n->size);
  n->data = copy;
  n->cap = n->size;
  n->written = 1;
}

static long fill_stat(struct node *n, const char *path, struct stat *st) {
  memset(st, 0, sizeof *st);
  st->st_nlink = 1;
  st->st_blksize = 4096;
  if (n) {
    st->st_mode = n->mode;
    st->st_size = (off_t)n->size;
    st->st_mtim.tv_sec = n->mtime;
    st->st_ino = (ino_t)n->ino;
  } else if (is_dir(path)) {
    st->st_mode = S_IFDIR | 0755;
    st->st_ino = 1;
  } else
    return -ENOENT;
  st->st_atim = st->st_ctim = st->st_mtim;
  return 0;
}

static struct ofile *ofile(long fd) {
  if (fd < RUN_FD_BASE || fd >= RUN_FD_BASE + RUN_FDS || !fds[fd - RUN_FD_BASE].open) return 0;
  return &fds[fd - RUN_FD_BASE];
}

static long new_fd(struct node *n, int flags) {
  for (int i = 0; i < RUN_FDS; i++)
    if (!fds[i].open) {
      fds[i].open = 1;
      fds[i].flags = flags;
      fds[i].node = n;
      fds[i].off = 0;
      return RUN_FD_BASE + i;
    }
  return -EMFILE;
}

static long run_open(const char *raw, int flags, int mode) {
  char path[2048];
  normalize(raw, path);
  struct node *n = find(path);
  if (!n && is_dir(path)) n = add(path, S_IFDIR | 0755);
  if (n && (n->mode & S_IFMT) == S_IFDIR) return new_fd(n, flags | O_DIRECTORY);
  if (!n) {
    if (!(flags & O_CREAT)) return -ENOENT;
    n = add(path, S_IFREG | (mode & 07777));
    n->written = 1;
  } else if ((flags & O_CREAT) && (flags & O_EXCL))
    return -EEXIST;
  if ((flags & O_ACCMODE) != O_RDONLY) {
    own(n);
    if (flags & O_TRUNC) n->size = 0;
  }
  return new_fd(n, flags);
}

static long run_rw(struct ofile *f, char *buf, size_t len, size_t *at, int writing) {
  struct node *n = f->node;
  if (!n) return -EISDIR;
  if (!writing) {
    if (*at >= n->size) return 0;
    if (len > n->size - *at) len = n->size - *at;
    memcpy(buf, n->data + *at, len);
    *at += len;
    return (long)len;
  }
  if ((f->flags & O_ACCMODE) == O_RDONLY) return -EBADF;
  if (f->flags & O_APPEND) *at = n->size;
  if (*at + len > n->cap) {
    size_t cap = n->cap ? n->cap : 4096;
    while (cap < *at + len) cap *= 2;
    n->data = realloc(n->data, cap);
    n->cap = cap;
  }
  if (*at > n->size) memset(n->data + n->size, 0, *at - n->size);
  memcpy(n->data + *at, buf, len);
  *at += len;
  if (*at > n->size) n->size = *at;
  return (long)len;
}

static void list_dir(struct ofile *f) {
  const char *dir = f->node->path;
  size_t len = strlen(dir), cap = 0;
  if (len == 1) len = 0;
  for (size_t i = 0; i < nnodes; i++) {
    struct node *n = nodes[i];
    if (n->dead || strncmp(n->path, dir, len) || n->path[len] != '/' || find(n->path) != n) continue;
    const char *rest = n->path + len + 1;
    const char *slash = strchr(rest, '/');
    size_t namelen = slash ? (size_t)(slash - rest) : strlen(rest);
    int dup = 0;
    for (size_t j = 0; j < f->nentries && !dup; j++)
      dup = strlen(f->entries[j].name) == namelen && !strncmp(f->entries[j].name, rest, namelen);
    if (dup) continue;
    if (f->nentries == cap) {
      cap = cap ? cap * 2 : 64;
      f->entries = realloc(f->entries, cap * sizeof *f->entries);
    }
    char *name = malloc(namelen + 1);
    memcpy(name, rest, namelen);
    name[namelen] = 0;
    f->entries[f->nentries].name = name;
    f->entries[f->nentries++].type = slash || (n->mode & S_IFMT) == S_IFDIR ? DT_DIR : DT_REG;
  }
}

static void drop_entries(struct ofile *f) {
  for (size_t i = 0; i < f->nentries; i++) free(f->entries[i].name);
  free(f->entries);
  f->entries = 0;
  f->nentries = 0;
}

static long run_readdir(struct ofile *f, long index, struct dirent *ent) {
  if (index == 0) {
    drop_entries(f);
    list_dir(f);
  }
  if ((size_t)index >= f->nentries) return 0;
  memset(ent, 0, sizeof *ent);
  strncpy(ent->d_name, f->entries[index].name, 255);
  ent->d_type = f->entries[index].type;
  ent->d_ino = (ino_t)index + 2;
  return 1;
}

static long run_vfs(long op, long a, long b, long c, long d) {
  char path[2048];
  struct ofile *f;
  if (a == 0 && stdin_fd >= 0 && op != VFS_open && op != VFS_stat && op != VFS_lstat && op != VFS_mkdir && op != VFS_unlink &&
      op != VFS_rmdir && op != VFS_rename && op != VFS_chdir && op != VFS_getcwd && op != VFS_realpath)
    a = stdin_fd;
  switch (op) {
  case VFS_open: return run_open((const char *)a, (int)b, (int)c);
  case VFS_close:
    if (!(f = ofile(a))) return -EBADF;
    drop_entries(f);
    f->open = 0;
    return 0;
  case VFS_read:
  case VFS_write:
    if (!(f = ofile(a))) return -EBADF;
    return run_rw(f, (char *)b, (size_t)c, &f->off, op == VFS_write);
  case VFS_pread:
  case VFS_pwrite: {
    if (!(f = ofile(a))) return -EBADF;
    size_t at = (size_t)d;
    return run_rw(f, (char *)b, (size_t)c, &at, op == VFS_pwrite);
  }
  case VFS_lseek: {
    if (!(f = ofile(a))) return -EBADF;
    long base = c == 0 ? 0 : c == 1 ? (long)f->off : (long)(f->node ? f->node->size : 0);
    if (base + b < 0) return -EINVAL;
    return (long)(f->off = (size_t)(base + b));
  }
  case VFS_stat:
  case VFS_lstat:
    normalize((const char *)a, path);
    return fill_stat(find(path), path, (struct stat *)b);
  case VFS_fstat:
    if (!(f = ofile(a))) return -EBADF;
    return fill_stat(f->node, f->node ? f->node->path : cwd, (struct stat *)b);
  case VFS_mkdir:
    normalize((const char *)a, path);
    if (find(path) || is_dir(path)) return -EEXIST;
    add(path, S_IFDIR | 0755)->written = 1;
    return 0;
  case VFS_rmdir:
  case VFS_unlink: {
    normalize((const char *)a, path);
    struct node *n = find(path);
    if (!n) return is_dir(path) ? 0 : -ENOENT;
    n->dead = 1;
    return 0;
  }
  case VFS_rename: {
    char to[2048];
    normalize((const char *)a, path);
    normalize((const char *)b, to);
    struct node *n = find(path);
    if (!n) return -ENOENT;
    struct node *old = find(to);
    if (old) old->dead = 1;
    own(n);
    struct node *m = add(to, n->mode);
    m->data = n->data;
    m->size = n->size;
    m->cap = n->cap;
    m->mtime = n->mtime;
    m->written = 1;
    n->dead = 1;
    for (int i = 0; i < RUN_FDS; i++)
      if (fds[i].open && fds[i].node == n) fds[i].node = m;
    return 0;
  }
  case VFS_chdir:
    normalize((const char *)a, path);
    if (!is_dir(path)) return -ENOENT;
    strcpy(cwd, path);
    return 0;
  case VFS_getcwd:
    if (strlen(cwd) + 1 > (size_t)b) return -ERANGE;
    strcpy((char *)a, cwd);
    return 0;
  case VFS_realpath:
    normalize((const char *)a, path);
    if (!find(path) && !is_dir(path)) return -ENOENT;
    if (strlen(path) + 1 > (size_t)c) return -ERANGE;
    strcpy((char *)b, path);
    return 0;
  case VFS_readdir:
    if (!(f = ofile(a))) return -EBADF;
    return run_readdir(f, b, (struct dirent *)c);
  case VFS_ftruncate:
    if (!(f = ofile(a)) || !f->node) return -EBADF;
    own(f->node);
    if ((size_t)b > f->node->cap) {
      f->node->data = realloc(f->node->data, (size_t)b);
      f->node->cap = (size_t)b;
    }
    if ((size_t)b > f->node->size) memset(f->node->data + f->node->size, 0, (size_t)b - f->node->size);
    f->node->size = (size_t)b;
    return 0;
  case VFS_fcntl:
    if (!ofile(a)) return -EBADF;
    return b == F_GETFL ? ofile(a)->flags : 0;
  case VFS_readlink: return -EINVAL;
  case VFS_chmod: case VFS_fchmod: case VFS_chown: case VFS_fchown: case VFS_utimes: case VFS_fsync: return 0;
  case VFS_umask: return 022;
  default: return -ENOSYS;
  }
}

void __libsa_vfs_register(long (*entry)(long, long, long, long, long));
void __libsa_run_core(const char *data, size_t size);

static long arg_size(int kind, long value, long len) {
  return kind == ARG_STRING ? (value ? (long)strlen((const char *)value) + 1 : 0) : kind == ARG_INT ? 0 : value ? len : 0;
}

static long port_vfs(long op, long a, long b, long c, long d) {
  long args[4] = {a, b, c, d};
  int kinds[4] = {ARG_INT, ARG_INT, ARG_INT, ARG_INT};
  long lens[4] = {0, 0, 0, 0};
  switch (op) {
  case VFS_open: case VFS_mkdir: case VFS_rmdir: case VFS_unlink: case VFS_chdir: case VFS_chmod: case VFS_chown:
  case VFS_truncate:
    kinds[0] = ARG_STRING; break;
  case VFS_symlink: case VFS_link: case VFS_rename:
    kinds[0] = kinds[1] = ARG_STRING; break;
  case VFS_read: case VFS_pread:
    if (args[2] > PORT_CHUNK) args[2] = PORT_CHUNK;
    kinds[1] = ARG_OUT; lens[1] = args[2]; break;
  case VFS_write: case VFS_pwrite:
    if (args[2] > PORT_CHUNK) args[2] = PORT_CHUNK;
    kinds[1] = ARG_IN; lens[1] = args[2]; break;
  case VFS_stat: case VFS_lstat:
    kinds[0] = ARG_STRING; kinds[1] = ARG_OUT; lens[1] = sizeof(struct stat); break;
  case VFS_fstat:
    kinds[1] = ARG_OUT; lens[1] = sizeof(struct stat); break;
  case VFS_readlink: case VFS_realpath:
    kinds[0] = ARG_STRING; kinds[1] = ARG_OUT; lens[1] = args[2] > 4096 ? 4096 : args[2]; break;
  case VFS_getcwd:
    kinds[0] = ARG_OUT; lens[0] = args[1] > 4096 ? 4096 : args[1]; break;
  case VFS_readdir:
    kinds[2] = ARG_OUT; lens[2] = sizeof(struct dirent); break;
  case VFS_utimes:
    kinds[0] = ARG_STRING; kinds[1] = ARG_IN; lens[1] = 32; break;
  case VFS_pipe:
    kinds[0] = ARG_OUT; lens[0] = 2 * sizeof(int); break;
  case VFS_waitpid:
    kinds[1] = ARG_OUT; lens[1] = sizeof(int); break;
  case VFS_close: case VFS_lseek: case VFS_fchdir: case VFS_fchmod: case VFS_fchown: case VFS_ftruncate:
  case VFS_dup: case VFS_dup2: case VFS_fcntl: case VFS_fsync: case VFS_umask:
    break;
  default:
    return -ENOSYS;
  }
  char *msg = malloc(PORT_MESSAGE), *reply = malloc(PORT_MESSAGE);
  if (!msg || !reply) { free(msg); free(reply); return -ENOMEM; }
  uint64_t *h = (uint64_t *)msg;
  uint32_t *sizes = (uint32_t *)(msg + 48);
  uint8_t *k = (uint8_t *)(msg + 64);
  h[0] = TAG_CALL;
  h[1] = (uint64_t)op;
  char *p = msg + PORT_HEADER;
  for (int i = 0; i < 4; i++) {
    long size = arg_size(kinds[i], args[i], lens[i]);
    h[2 + i] = kinds[i] == ARG_INT ? (uint64_t)args[i] : 0;
    sizes[i] = (uint32_t)size;
    k[i] = (uint8_t)kinds[i];
    if ((kinds[i] == ARG_STRING || kinds[i] == ARG_IN) && size) {
      if (p + size > msg + PORT_MESSAGE) { free(msg); free(reply); return -ENAMETOOLONG; }
      memcpy(p, (const void *)args[i], (size_t)size);
      p += size;
    }
  }
  long n = __machdep5(MACHDEP_port_call, (long)record->port, (long)msg, p - msg, (long)reply, PORT_MESSAGE);
  long r = n < 24 ? -EIO : *(int64_t *)reply;
  if (n >= 24) {
    uint32_t *got = (uint32_t *)(reply + 8);
    char *q = reply + 24;
    for (int i = 0; i < 4; i++)
      if (kinds[i] == ARG_OUT && got[i] && args[i]) {
        if (q + got[i] > reply + n) break;
        memcpy((void *)args[i], q, got[i]);
        q += got[i];
      }
  }
  free(msg);
  free(reply);
  return r;
}

void __libsa_vfs_boot_first(void);

const char *__libsa_run_start(int *argc, char **argv, int max) {
  uint64_t k[2] = {0, 0};
  __machdep(MACHDEP_core_file, (long)k, 0);
  struct record *r = (struct record *)k[0];
  if (!r || k[1] < sizeof *r || r->magic != RUN_MAGIC) return 0;
  record = r;
  __libsa_run_core((const char *)r->core, r->core_size);
  if (r->result) return 0;
  if (r->disk) {
    __libsa_vfs_boot_first();
    __libsa_vfs_register(port_vfs);
    *argc = 0;
    for (const char *p = (const char *)r->argv; p < (const char *)r->argv + r->argv_size && *argc < max - 1; p += strlen(p) + 1)
      argv[(*argc)++] = (char *)p;
    argv[*argc] = 0;
    return (const char *)r;
  }
  load_archive((const char *)r->archive, r->archive_size);
  struct node *core = add("/System/Library/Kernels/darterfly.core", S_IFREG | 0444);
  core->data = (char *)r->core;
  core->size = r->core_size;
  uint64_t kernel[2] = {0, 0};
  __machdep(MACHDEP_kernel_file, (long)kernel, 0);
  struct node *image = add("/System/Library/Kernels/kernel", S_IFREG | 0555);
  image->data = (char *)kernel[0];
  image->size = kernel[1];
  if (r->cwd) strncpy(cwd, (const char *)r->cwd, sizeof cwd - 1);
  __libsa_vfs_register(run_vfs);
  if (r->stdin_path) {
    long fd = run_open((const char *)r->stdin_path, O_RDONLY, 0);
    if (fd >= 0) stdin_fd = (int)fd;
  }
  *argc = 0;
  for (const char *p = (const char *)r->argv; p < (const char *)r->argv + r->argv_size && *argc < max - 1; p += strlen(p) + 1)
    argv[(*argc)++] = (char *)p;
  argv[*argc] = 0;
  return (const char *)r;
}

int __libsa_run_active(void) { return record && !record->result; }

int __libsa_run_stdin(void) { return stdin_fd >= 0; }

int __libsa_run_result(uint64_t *archive, uint64_t *size, uint64_t *code) {
  if (!record || !record->result) return 0;
  *archive = record->archive;
  *size = record->archive_size;
  *code = record->exit_code;
  return 1;
}

static char *put_hex(char *p, uint64_t v) {
  static const char digits[] = "0123456789abcdef";
  for (int i = 7; i >= 0; i--) p[7 - i] = digits[(v >> (4 * i)) & 15];
  return p + 8;
}

static char *put_entry(char *p, const char *name, const char *data, size_t size, uint32_t mode, int64_t mtime, size_t ino) {
  char *start = p;
  memcpy(p, "070701", 6);
  p += 6;
  uint64_t fields[13] = {ino, mode, 0, 0, 1, (uint64_t)mtime, size, 0, 0, 0, 0, strlen(name) + 1, 0};
  for (int i = 0; i < 13; i++) p = put_hex(p, fields[i]);
  strcpy(p, name);
  p = start + pad4(110 + strlen(name) + 1);
  memset(start + 110 + strlen(name) + 1, 0, (size_t)(p - (start + 110 + strlen(name) + 1)));
  if (size) memcpy(p, data, size);
  char *end = p + pad4(size);
  memset(p + size, 0, (size_t)(end - (p + size)));
  return end;
}

void __libsa_run_finish(int code) {
  if (!__libsa_run_active()) return;
  struct record *out = mmap((void *)RUN_OUT_BASE, RUN_OUT_SPACE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
  if (out == MAP_FAILED) return;
  char *p = (char *)(out + 1);
  char *archive = p;
  for (size_t i = 0; i < nnodes; i++) {
    struct node *n = nodes[i];
    if (n->dead || !n->written || find(n->path) != n) continue;
    p = put_entry(p, n->path, n->data, (n->mode & S_IFMT) == S_IFDIR ? 0 : n->size, n->mode, n->mtime, i + 1);
  }
  p = put_entry(p, "TRAILER!!!", 0, 0, 0, 0, 0);
  if (record->port) {
    uint64_t head[3] = {TAG_EXIT, (uint64_t)(unsigned)code, (uint64_t)(p - archive)}, ack;
    __machdep5(MACHDEP_port_call, (long)record->port, (long)head, sizeof head, (long)&ack, sizeof ack);
    for (char *q = archive; q < p; q += RUN_CHUNK) {
      char *chunk = q - 8;
      uint64_t saved;
      memcpy(&saved, chunk, 8);
      uint64_t tag = TAG_FILES;
      memcpy(chunk, &tag, 8);
      __machdep5(MACHDEP_port_call, (long)record->port, (long)chunk, (p - q < RUN_CHUNK ? p - q : RUN_CHUNK) + 8, (long)&ack, sizeof ack);
      memcpy(chunk, &saved, 8);
    }
    return;
  }
  char *core = (char *)(((uint64_t)p + 4095) & ~4095ull);
  memcpy(core, (const void *)record->back_core, record->back_size);
  memset(out, 0, sizeof *out);
  out->magic = RUN_MAGIC;
  out->core = (uint64_t)core;
  out->core_size = record->back_size;
  out->archive = (uint64_t)archive;
  out->archive_size = (uint64_t)(p - archive);
  out->result = 1;
  out->exit_code = (uint64_t)(unsigned)code;
  __machdep(MACHDEP_restart, (long)out, (long)(core + record->back_size - (char *)out));
}
