package llvm

// Error.h

// when true: see LLVM_LINKER_FLAGS in llvm.odin.
when true {
	@(ignore_duplicates, extra_linker_flags = LLVM_LINKER_FLAGS)
	foreign import lib {LLVM_C_LIB}
}

LLVMOpaqueError :: struct {}
LLVMErrorRef :: ^LLVMOpaqueError

@(default_calling_convention = "c")
foreign lib {
	// Consumes Err. The returned text is released with LLVMDisposeErrorMessage.
	LLVMGetErrorMessage :: proc(Err: LLVMErrorRef) -> cstring ---
	LLVMDisposeErrorMessage :: proc(ErrMsg: cstring) ---
}
