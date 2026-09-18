/*
Raw bindings to the LLVM-C 20 API, the subset the compiler uses.

Version: LLVM 20.1.0, the build that ships with Odin dev-2026-09-nightly:a2fb372. Every declaration
is copied from the headers at https://github.com/llvm/llvm-project/tree/llvmorg-20.1.0/llvm/include/llvm-c,
one Odin file per header. A task that needs another function adds it to its header's file.

Library:
- Windows: windows/LLVM-C.lib is the import library for LLVM-C.dll, vendored unchanged from
  https://raw.githubusercontent.com/odin-lang/Odin/a2fb372/bin/llvm/windows/LLVM-C.lib
  (git blob 6230de057b99beb226a74f97185aed6591486c18). LLVM-C.dll sits next to odin.exe and must be
  on PATH when a program built with this package runs. License: Apache-2.0 WITH LLVM-exception.
- Linux: libLLVM-20.so of Ubuntu's and Debian's libllvm20 package, which llvm-20-dev installs, on
  the linker's default search path.
- macOS: Homebrew's llvm@20. The formula is keg-only, so its lib directory is off the linker's
  search path, and LLVM_LINKER_FLAGS passes it: Homebrew's default prefix on Apple silicon and on
  Intel. For LLVM 20 elsewhere, add -extra-linker-flags:-L<dir> to odin build, run and test.
The name LLVM-20 pins the major version: without LLVM 20 the program fails to link rather than
loading another version with a different API.

Names are exactly as in C, enum members included. Types map as follows: LLVMBool is b32, unsigned is
u32, int is i32, uint64_t and unsigned long long are u64, size_t is uint, char pointers are cstring,
a pointer to an array is [^]T, an out parameter is ^T.

Ownership: every handle from a create call has a matching dispose, and every char pointer LLVM
returns is released with the procedure its header names, usually LLVMDisposeMessage. Types, values,
basic blocks and attributes belong to their context and go away with it.

Results: LLVMVerifyModule, LLVMGetTargetFromTriple, LLVMPrintModuleToFile and the
LLVMTargetMachineEmitTo* procedures return true on failure and put a message in their out parameter.

Threads: one context per thread. Target initialization and LLVMParseCommandLineOptions change
process-global state; call them once, before any other thread uses LLVM.
*/
package llvm

// LLVM_LINKER_FLAGS goes on the foreign import of core.odin only, the file every LLVM user calls
// into; Odin drops an empty value. Odin writes a library's flags with no space after them, so the
// next flag sticks to them unless the library itself follows: priority_index puts that import
// first in the link order, where its -lLLVM-20 comes right after the flags. The import sits in a
// `when true` block: an attribute at file level sees only built-in constants, one inside a when
// block sees package constants too. The constants themselves stay out of when blocks: Odin
// resolves those file by file, and core.odin sorts before this file.
@(private)
LLVM_C_LIB :: "windows/LLVM-C.lib" when ODIN_OS == .Windows else "system:LLVM-20"
@(private)
HOMEBREW_PREFIX :: "/opt/homebrew" when ODIN_ARCH == .arm64 else "/usr/local"
@(private)
LLVM_LINKER_FLAGS :: "-L" + HOMEBREW_PREFIX + "/opt/llvm@20/lib" when ODIN_OS == .Darwin else ""

// Types.h

LLVMBool :: b32

LLVMOpaqueMemoryBuffer :: struct {}
LLVMMemoryBufferRef :: ^LLVMOpaqueMemoryBuffer

LLVMOpaqueContext :: struct {}
LLVMContextRef :: ^LLVMOpaqueContext

LLVMOpaqueModule :: struct {}
LLVMModuleRef :: ^LLVMOpaqueModule

LLVMOpaqueType :: struct {}
LLVMTypeRef :: ^LLVMOpaqueType

LLVMOpaqueValue :: struct {}
LLVMValueRef :: ^LLVMOpaqueValue

LLVMOpaqueBasicBlock :: struct {}
LLVMBasicBlockRef :: ^LLVMOpaqueBasicBlock

LLVMOpaqueBuilder :: struct {}
LLVMBuilderRef :: ^LLVMOpaqueBuilder

LLVMOpaqueAttributeRef :: struct {}
LLVMAttributeRef :: ^LLVMOpaqueAttributeRef
