package llvm

// Error.h

@(ignore_duplicates)
foreign import lib {LLVM_C_LIB}

LLVMOpaqueError :: struct {}
LLVMErrorRef :: ^LLVMOpaqueError

@(default_calling_convention = "c")
foreign lib {
	// Consumes Err. The returned text is released with LLVMDisposeErrorMessage.
	LLVMGetErrorMessage :: proc(Err: LLVMErrorRef) -> cstring ---
	LLVMDisposeErrorMessage :: proc(ErrMsg: cstring) ---
}
