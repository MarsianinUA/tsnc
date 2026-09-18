package llvm

// Support.h

@(ignore_duplicates)
foreign import lib {LLVM_C_LIB}

@(default_calling_convention = "c")
foreign lib {
	LLVMParseCommandLineOptions :: proc(argc: i32, argv: [^]cstring, Overview: cstring) ---
}
