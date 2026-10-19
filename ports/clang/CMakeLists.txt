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
    ${LLVM_MAIN_SRC_DIR}/../clang/tools/driver/cc1as_main.cpp
    DEPENDS intrinsics_gen ARMTargetParserTableGen AArch64TargetParserTableGen)
target_link_libraries(darter-clang PRIVATE clangBasic clangCodeGen clangDriver
    clangFrontend clangFrontendTool clangSerialization)

set_target_properties(darter-clang PROPERTIES SUFFIX ".o")
add_dependencies(darter-clang clang-resource-headers)

# The ELF linker uses exactly the same target sysroot and LLVM libraries.
include_directories(${LLVM_MAIN_SRC_DIR}/../lld/include
                    ${LLVM_BINARY_DIR}/tools/lld/include)
set(LLVM_LINK_COMPONENTS ${LLVM_TARGETS_TO_BUILD} BinaryFormat BitWriter Core
    DebugInfoDWARF Demangle LTO MC Object Option Passes Support TargetParser
    TransformUtils)
add_llvm_executable(darter-lld ../lld/main.cpp)
target_link_libraries(darter-lld PRIVATE lldELF lldCommon)
set_target_properties(darter-lld PROPERTIES SUFFIX ".o")

# Archive operations use the upstream entry, including ranlib dispatch.
set(LLVM_LINK_COMPONENTS AllTargetsAsmParsers AllTargetsDescs AllTargetsInfos
    BinaryFormat Core DlltoolDriver LibDriver Object Support TargetParser)
add_llvm_executable(darter-llvm-ar ../llvm-tools/ar-main.cpp
    ${LLVM_MAIN_SRC_DIR}/tools/llvm-ar/llvm-ar.cpp DEPENDS intrinsics_gen)
set_target_properties(darter-llvm-ar PROPERTIES SUFFIX ".o")

# Reuse upstream's complete generator source and library lists. Host generators
# remain separate: cross-build custom commands must never execute these seeds.
foreach(generator llvm-tblgen clang-tblgen)
  get_target_property(generator_dir ${generator} SOURCE_DIR)
  get_target_property(generator_sources ${generator} SOURCES)
  set(native_sources)
  foreach(source IN LISTS generator_sources)
    if(IS_ABSOLUTE "${source}" OR source MATCHES "^\\$<")
      list(APPEND native_sources "${source}")
    else()
      list(APPEND native_sources "${generator_dir}/${source}")
    endif()
  endforeach()
  set(LLVM_LINK_COMPONENTS)
  add_llvm_executable(darter-${generator} ${native_sources})
  get_target_property(generator_includes ${generator} INCLUDE_DIRECTORIES)
  target_include_directories(darter-${generator} PRIVATE
      ${generator_dir} ${generator_includes})
  get_target_property(generator_libs ${generator} LINK_LIBRARIES)
  target_link_libraries(darter-${generator} PRIVATE ${generator_libs})
  set_target_properties(darter-${generator} PROPERTIES SUFFIX ".o")
endforeach()
