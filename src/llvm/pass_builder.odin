package llvm

// Transforms/PassBuilder.h

// when true: see LLVM_LINKER_FLAGS in llvm.odin.
when true {
	@(ignore_duplicates, extra_linker_flags = LLVM_LINKER_FLAGS)
	foreign import lib {LLVM_C_LIB}
}

LLVMOpaquePassBuilderOptions :: struct {}
LLVMPassBuilderOptionsRef :: ^LLVMOpaquePassBuilderOptions

@(default_calling_convention = "c")
foreign lib {
	// Passes is a pipeline in opt syntax, for example "default<O2>". Returns nil on success.
	LLVMRunPasses :: proc(M: LLVMModuleRef, Passes: cstring, TM: LLVMTargetMachineRef, Options: LLVMPassBuilderOptionsRef) -> LLVMErrorRef ---
	LLVMCreatePassBuilderOptions :: proc() -> LLVMPassBuilderOptionsRef ---
	LLVMDisposePassBuilderOptions :: proc(Options: LLVMPassBuilderOptionsRef) ---
}
