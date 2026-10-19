#pragma once
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
struct statvfs {
  unsigned long f_bsize, f_frsize, f_blocks, f_bfree, f_bavail;
  unsigned long f_files, f_ffree, f_favail, f_fsid, f_flag, f_namemax;
  unsigned long f_flags;
};
#define MNT_LOCAL 0x1000
int statvfs(const char *, struct statvfs *);
int fstatvfs(int, struct statvfs *);
#ifdef __cplusplus
}
#endif
