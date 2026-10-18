# The host resolves archives/COMDAT into ET_REL. Lisp performs the final link
# with the shared Low libsa. No host startup files or libc enter the image.
set(CMAKE_CXX_LINK_EXECUTABLE
    "${Python3_EXECUTABLE} ${CMAKE_CURRENT_LIST_DIR}/../../tools/link-clang-seed.py <OBJECTS> <LINK_LIBRARIES> -o <TARGET>")
# Use upstream cc1 unchanged. Only the driver entry point is Darterfly-specific.
include_directories(${LLVM_MAIN_SRC_DIR}/../clang/include ${LLVM_BINARY_DIR}/tools/clang/include)
set(LLVM_LINK_COMPONENTS ${LLVM_TARGETS_TO_BUILD} Analysis CodeGen Core IPO
    AggressiveInstCombine InstCombine Instrumentation MC MCParser ObjCARCOpts
    Option ScalarOpts Support TargetParser TransformUtils Vectorize)
add_llvm_executable(darter-clang main.cpp
    ${LLVM_MAIN_SRC_DIR}/../clang/tools/driver/cc1_main.cpp
    DEPENDS intrinsics_gen ARMTargetParserTableGen AArch64TargetParserTableGen)
target_link_libraries(darter-clang PRIVATE clangBasic clangCodeGen clangDriver
    clangFrontend clangFrontendTool clangSerialization)

set_target_properties(darter-clang PROPERTIES SUFFIX ".o")
add_dependencies(darter-clang clang-resource-headers)
