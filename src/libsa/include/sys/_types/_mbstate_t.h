#pragma once
#include <stdint.h>
/* C++ iosfwd needs the state type even with wide-character I/O disabled.
   No multibyte conversion or wide I/O functions are supplied yet. */
typedef struct { uint32_t pending, value; } mbstate_t;
