// Native frontend/assembler entry points; upstream implementations unchanged.
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/Allocator.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/StringSaver.h"
#include <cstdio>
#include <cstring>
int cc1_main(llvm::ArrayRef<const char *>, const char *, void *);
int cc1as_main(llvm::ArrayRef<const char *>, const char *, void *);
int main(int argc, char **argv) {
  llvm::BumpPtrAllocator allocator;
  llvm::StringSaver saver(allocator);
  llvm::SmallVector<const char *, 64> args(argv, argv + argc);
  if (!llvm::cl::ExpandResponseFiles(saver, llvm::cl::TokenizeGNUCommandLine, args))
    return 1;
  if (args.size() < 2 || (strcmp(args[1], "-cc1") && strcmp(args[1], "-cc1as"))) {
    fputs("usage: clang {-cc1|-cc1as} <arguments>\n", stderr);
    return 1;
  }
  auto entry = !strcmp(args[1], "-cc1as") ? cc1as_main : cc1_main;
  return entry(llvm::ArrayRef<const char *>(args).drop_front(2), args[0],
               reinterpret_cast<void *>(&main));
}
