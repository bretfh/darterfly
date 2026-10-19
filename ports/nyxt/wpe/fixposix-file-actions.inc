/* Translate the existing upstream action representation at its definition. */
#include <spawn.h>
int lfp_darter_file_actions(const lfp_spawn_file_actions_t *files,
                           posix_spawn_file_actions_t *native)
{
    if (!files) return 0;
    if (files->keep_descriptors)
        for (int fd=0; fd<files->kfd_size; ++fd)
            if (bitset_contains(files->kfd,fd)) {
                int error=posix_spawn_file_actions_adddup2(native,fd,fd);
                if (error) return error;
            }
    for (unsigned i=0; i<files->initialized; ++i) {
        const lfp_spawn_action *action=files->actions+i;
        int error;
        switch (action->type) {
        case LFP_SPAWN_FILE_ACTION_OPEN:
            if (action->flags > UINT_MAX) return ENOTSUP;
            error=posix_spawn_file_actions_addopen(native,action->fd,
                action->path,(int)action->flags,action->mode); break;
        case LFP_SPAWN_FILE_ACTION_CLOSE:
            error=posix_spawn_file_actions_addclose(native,action->fd); break;
        case LFP_SPAWN_FILE_ACTION_DUP2:
            error=posix_spawn_file_actions_adddup2(native,action->fd,
                action->newfd); break;
        default: return EINVAL;
        }
        if (error) return error;
    }
    return 0;
}
