#include <llvm/Demangle/Demangle.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
int main() {
    char *name = llvm::itaniumDemangle("_Z3foov");
    if (!name || std::strcmp(name, "foo()")) return 90;
    std::free(name);
    if (llvm::itaniumDemangle("not a mangled name")) return 91;
    std::puts("[CLANG LLVM-COMPONENT PASS]");
    return 44;
}
