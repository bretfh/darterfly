#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/types.h>
#include <signal.h>
typedef struct { short flags; pid_t pgroup; sigset_t mask, def; } posix_spawnattr_t;
typedef struct { int n; void *actions; } posix_spawn_file_actions_t;
#define POSIX_SPAWN_RESETIDS 1
#define POSIX_SPAWN_SETPGROUP 2
#define POSIX_SPAWN_SETSIGDEF 4
#define POSIX_SPAWN_SETSIGMASK 8
#define POSIX_SPAWN_SETSID 0x80
/* Close inherited descriptors >=3 unless a file action explicitly preserves them. */
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
int posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                char *const[], char *const[]);
int posix_spawnp(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                 char *const[], char *const[]);
int posix_spawnattr_init(posix_spawnattr_t *);
int posix_spawnattr_destroy(posix_spawnattr_t *);
int posix_spawnattr_setflags(posix_spawnattr_t *, short);
int posix_spawnattr_setpgroup(posix_spawnattr_t *, pid_t);
int posix_spawnattr_setsigmask(posix_spawnattr_t *, const sigset_t *);
int posix_spawnattr_setsigdefault(posix_spawnattr_t *, const sigset_t *);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *, int, int);
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *, int, const char *, int, mode_t);
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *, int);
int posix_spawn_file_actions_addclosefrom_np(posix_spawn_file_actions_t *, int);
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);

#ifdef __cplusplus
}
#endif
