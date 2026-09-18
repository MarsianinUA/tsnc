package llvm

// Support.h

// when true: see LLVM_LINKER_FLAGS in llvm.odin.
when true {
	@(ignore_duplicates, extra_linker_flags = LLVM_LINKER_FLAGS)
	foreign import lib {LLVM_C_LIB}
}

@(default_calling_convention = "c")
foreign lib {
	LLVMParseCommandLineOptions :: proc(argc: i32, argv: [^]cstring, Overview: cstring) ---
}
