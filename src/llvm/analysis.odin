package llvm

// Analysis.h

// when true: see LLVM_LINKER_FLAGS in llvm.odin.
when true {
	@(ignore_duplicates, extra_linker_flags = LLVM_LINKER_FLAGS)
	foreign import lib {LLVM_C_LIB}
}

LLVMVerifierFailureAction :: enum i32 {
	LLVMAbortProcessAction = 0, // prints to stderr and calls abort()
	LLVMPrintMessageAction = 1, // prints to stderr and returns true
	LLVMReturnStatusAction = 2, // only returns true
}

@(default_calling_convention = "c")
foreign lib {
	LLVMVerifyModule :: proc(M: LLVMModuleRef, Action: LLVMVerifierFailureAction, OutMessage: ^cstring) -> LLVMBool ---
}
