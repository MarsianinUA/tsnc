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
- Linux and macOS: the system LLVM 20 (-lLLVM). How the linker finds its lib directory is set up
  with CI in T1.9.

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

when ODIN_OS == .Windows {
	@(private)
	LLVM_C_LIB :: "windows/LLVM-C.lib"
} else {
	@(private)
	LLVM_C_LIB :: "system:LLVM"
}

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
