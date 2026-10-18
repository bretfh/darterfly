// Keep the upstream archive implementation and its argv[0] dispatch intact.
#include "llvm/Support/LLVMDriver.h"
int llvm_ar_main(int, char **, const llvm::ToolContext &);
int main(int argc, char **argv) {
  return llvm_ar_main(argc, argv, {argv[0], nullptr, false});
}
