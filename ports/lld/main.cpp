// One ELF linker invocation per native world; upstream LLD is unchanged.
#include "lld/Common/Driver.h"
#include "llvm/Support/raw_ostream.h"
LLD_HAS_DRIVER(elf)
int main(int argc, char **argv) {
  return lld::lldMain(llvm::ArrayRef<const char *>(argv, argc), llvm::outs(),
                      llvm::errs(), {{lld::Gnu, &lld::elf::link}}).retCode;
}
