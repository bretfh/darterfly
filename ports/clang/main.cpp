// The compiler runs in a native Darterfly world. No host RPC/compiler service.
#include "llvm/ADT/ArrayRef.h"
#include <cstdio>
#include <cstring>
int cc1_main(llvm::ArrayRef<const char *>, const char *, void *);
int main(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "-cc1")) {
    fputs("usage: clang -cc1 <frontend arguments>\n", stderr);
    return 1;
  }
  return cc1_main(llvm::ArrayRef<const char *>(argv + 2, argc - 2), argv[0],
                  reinterpret_cast<void *>(&main));
}
