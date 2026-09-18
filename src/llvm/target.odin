package llvm

// Target.h

// when true: see LLVM_LINKER_FLAGS in llvm.odin.
when true {
	@(ignore_duplicates, extra_linker_flags = LLVM_LINKER_FLAGS)
	foreign import lib {LLVM_C_LIB}
}

LLVMOpaqueTargetData :: struct {}
LLVMTargetDataRef :: ^LLVMOpaqueTargetData

// The header's LLVMInitializeNative* and LLVMInitializeAll* helpers are static inline, so LLVM-C.dll
// does not export them. Callers initialize each target they emit for with the four calls below.
@(default_calling_convention = "c")
foreign lib {
	LLVMInitializeX86TargetInfo :: proc() ---
	LLVMInitializeX86Target :: proc() ---
	LLVMInitializeX86TargetMC :: proc() ---
	LLVMInitializeX86AsmPrinter :: proc() ---

	LLVMInitializeAArch64TargetInfo :: proc() ---
	LLVMInitializeAArch64Target :: proc() ---
	LLVMInitializeAArch64TargetMC :: proc() ---
	LLVMInitializeAArch64AsmPrinter :: proc() ---

	LLVMSetModuleDataLayout :: proc(M: LLVMModuleRef, DL: LLVMTargetDataRef) ---
	LLVMDisposeTargetData :: proc(TD: LLVMTargetDataRef) ---
}
