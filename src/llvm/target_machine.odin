package llvm

// TargetMachine.h

@(ignore_duplicates)
foreign import lib {LLVM_C_LIB}

LLVMOpaqueTargetMachine :: struct {}
LLVMTargetMachineRef :: ^LLVMOpaqueTargetMachine

// Owned by the LLVM target registry, never released.
LLVMTarget :: struct {}
LLVMTargetRef :: ^LLVMTarget

LLVMCodeGenOptLevel :: enum i32 {
	LLVMCodeGenLevelNone       = 0,
	LLVMCodeGenLevelLess       = 1,
	LLVMCodeGenLevelDefault    = 2,
	LLVMCodeGenLevelAggressive = 3,
}

LLVMRelocMode :: enum i32 {
	LLVMRelocDefault      = 0,
	LLVMRelocStatic       = 1,
	LLVMRelocPIC          = 2,
	LLVMRelocDynamicNoPic = 3,
	LLVMRelocROPI         = 4,
	LLVMRelocRWPI         = 5,
	LLVMRelocROPI_RWPI    = 6,
}

LLVMCodeModel :: enum i32 {
	LLVMCodeModelDefault    = 0,
	LLVMCodeModelJITDefault = 1,
	LLVMCodeModelTiny       = 2,
	LLVMCodeModelSmall      = 3,
	LLVMCodeModelKernel     = 4,
	LLVMCodeModelMedium     = 5,
	LLVMCodeModelLarge      = 6,
}

LLVMCodeGenFileType :: enum i32 {
	LLVMAssemblyFile = 0,
	LLVMObjectFile   = 1,
}

@(default_calling_convention = "c")
foreign lib {
	LLVMGetTargetFromTriple :: proc(Triple: cstring, T: ^LLVMTargetRef, ErrorMessage: ^cstring) -> LLVMBool ---
	LLVMCreateTargetMachine :: proc(T: LLVMTargetRef, Triple: cstring, CPU: cstring, Features: cstring, Level: LLVMCodeGenOptLevel, Reloc: LLVMRelocMode, CodeModel: LLVMCodeModel) -> LLVMTargetMachineRef ---
	LLVMDisposeTargetMachine :: proc(T: LLVMTargetMachineRef) ---
	LLVMCreateTargetDataLayout :: proc(T: LLVMTargetMachineRef) -> LLVMTargetDataRef ---
	LLVMTargetMachineEmitToFile :: proc(T: LLVMTargetMachineRef, M: LLVMModuleRef, Filename: cstring, codegen: LLVMCodeGenFileType, ErrorMessage: ^cstring) -> LLVMBool ---
	LLVMTargetMachineEmitToMemoryBuffer :: proc(T: LLVMTargetMachineRef, M: LLVMModuleRef, codegen: LLVMCodeGenFileType, ErrorMessage: ^cstring, OutMemBuf: ^LLVMMemoryBufferRef) -> LLVMBool ---
	LLVMGetDefaultTargetTriple :: proc() -> cstring ---
}
