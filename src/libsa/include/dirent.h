#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/types.h>
#define DT_UNKNOWN 0
#define DT_WHT 14
#define d_fileno d_ino
#define DT_FIFO 1
#define DT_CHR 2
#define DT_BLK 6
#define DT_SOCK 12
#define DT_DIR 4
#define DT_REG 8
#define DT_LNK 10
struct dirent {
  ino_t d_ino;
  off_t d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[256];
};
typedef struct __DIR DIR;
DIR *opendir(const char *);
DIR *fdopendir(int);
struct dirent *readdir(DIR *);
int readdir_r(DIR *, struct dirent *, struct dirent **);
long telldir(DIR *);
void seekdir(DIR *, long);
int closedir(DIR *);
void rewinddir(DIR *);
struct dirent *readdir64(DIR *);
int dirfd(DIR *);
struct dirent64 {
  ino64_t d_ino;
  off64_t d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[256];
};

#ifdef __cplusplus
}
#endif
