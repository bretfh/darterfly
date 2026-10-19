#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#include <sys/socket.h>
struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };

#ifdef __cplusplus
}
#endif
