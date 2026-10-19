#pragma once
#include <stdint.h>
/* Conversion state for the stateless C locale. Reserved for future UTF-8. */
typedef struct { uint32_t pending, value; } mbstate_t;
