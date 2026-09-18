package llvm

// Analysis.h

@(ignore_duplicates)
foreign import lib {LLVM_C_LIB}

LLVMVerifierFailureAction :: enum i32 {
	LLVMAbortProcessAction = 0, // prints to stderr and calls abort()
	LLVMPrintMessageAction = 1, // prints to stderr and returns true
	LLVMReturnStatusAction = 2, // only returns true
}

@(default_calling_convention = "c")
foreign lib {
	LLVMVerifyModule :: proc(M: LLVMModuleRef, Action: LLVMVerifierFailureAction, OutMessage: ^cstring) -> LLVMBool ---
}
