#pragma once
#include <stdatomic.h>
#ifndef __builtin_huge_val
#define __builtin_huge_val() 1e500
#define __builtin_huge_valf() 1e50f
#define __builtin_huge_vall() 1e5000L
#define __builtin_nanf(ignored) (0.0F / 0.0F)
#endif
#undef __atomic_store_n
#define __atomic_store_n(p, v, o) \
  ({ typeof(*(p)) __s = (v); __atomic_store((p), &__s, (o)); })
#define __atomic_exchange_n(p, v, o) \
  ({ typeof(*(p)) __v = (v), __r; __atomic_exchange((p), &__v, &__r, (o)); __r; })
#define __atomic_test_and_set(p, o) ((_Bool)__atomic_exchange_n((unsigned char *)(p), 1, (o)))
#define __atomic_clear(p, o) __atomic_store_n((unsigned char *)(p), 0, (o))
#define __sync_val_compare_and_swap(p, o, n) \
  ({ typeof(*(p)) __e = (o); __atomic_compare_exchange_n((p), &__e, (n), 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); __e; })
#define __sync_bool_compare_and_swap(p, o, n) \
  ({ typeof(*(p)) __e = (o); __atomic_compare_exchange_n((p), &__e, (n), 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); })
#define __sync_fetch_and_add(p, v) __atomic_fetch_add((p), (v), __ATOMIC_SEQ_CST)
#define __sync_fetch_and_sub(p, v) __atomic_fetch_sub((p), (v), __ATOMIC_SEQ_CST)
#define __sync_fetch_and_or(p, v) __atomic_fetch_or((p), (v), __ATOMIC_SEQ_CST)
#define __sync_fetch_and_and(p, v) __atomic_fetch_and((p), (v), __ATOMIC_SEQ_CST)
#define __sync_add_and_fetch(p, v) __atomic_add_fetch((p), (v), __ATOMIC_SEQ_CST)
#define __sync_xor_and_fetch(p, v) __atomic_xor_fetch((p), (v), __ATOMIC_SEQ_CST)
