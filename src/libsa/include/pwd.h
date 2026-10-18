#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/types.h>
struct passwd { char *pw_name, *pw_passwd; uid_t pw_uid; gid_t pw_gid; char *pw_gecos, *pw_dir, *pw_shell; };
int getpwuid_r(uid_t, struct passwd *, char *, size_t, struct passwd **);
int getpwnam_r(const char *, struct passwd *, char *, size_t, struct passwd **);
struct passwd *getpwuid(uid_t);
struct passwd *getpwnam(const char *);

#ifdef __cplusplus
}
#endif
