#pragma once
#include <netinet/in.h>
const char *inet_ntop(int, const void *, char *, socklen_t);
int inet_pton(int, const char *, void *);
