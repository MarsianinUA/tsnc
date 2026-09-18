package llvm

// Core.h

// when true: see LLVM_LINKER_FLAGS in llvm.odin.
when true {
	@(ignore_duplicates, extra_linker_flags = LLVM_LINKER_FLAGS)
	foreign import lib {LLVM_C_LIB}
}

LLVMLinkage :: enum i32 {
	LLVMExternalLinkage            = 0,
	LLVMAvailableExternallyLinkage = 1,
	LLVMLinkOnceAnyLinkage         = 2,
	LLVMLinkOnceODRLinkage         = 3,
	LLVMLinkOnceODRAutoHideLinkage = 4,
	LLVMWeakAnyLinkage             = 5,
	LLVMWeakODRLinkage             = 6,
	LLVMAppendingLinkage           = 7,
	LLVMInternalLinkage            = 8,
	LLVMPrivateLinkage             = 9,
	LLVMDLLImportLinkage           = 10,
	LLVMDLLExportLinkage           = 11,
	LLVMExternalWeakLinkage        = 12,
	LLVMGhostLinkage               = 13,
	LLVMCommonLinkage              = 14,
	LLVMLinkerPrivateLinkage       = 15,
	LLVMLinkerPrivateWeakLinkage   = 16,
}

LLVMUnnamedAddr :: enum i32 {
	LLVMNoUnnamedAddr     = 0,
	LLVMLocalUnnamedAddr  = 1,
	LLVMGlobalUnnamedAddr = 2,
}

LLVMAttributeIndex :: u32

LLVMAttributeReturnIndex :: LLVMAttributeIndex(0)
// C declares it as -1 in an enum of unsigned indices.
LLVMAttributeFunctionIndex :: LLVMAttributeIndex(0xFFFF_FFFF)

@(default_calling_convention = "c")
foreign lib {
	LLVMGetVersion :: proc(Major, Minor, Patch: ^u32) ---
	LLVMDisposeMessage :: proc(Message: cstring) ---

	LLVMContextCreate :: proc() -> LLVMContextRef ---
	LLVMContextDispose :: proc(C: LLVMContextRef) ---
	LLVMGetEnumAttributeKindForName :: proc(Name: cstring, SLen: uint) -> u32 ---
	LLVMCreateEnumAttribute :: proc(C: LLVMContextRef, KindID: u32, Val: u64) -> LLVMAttributeRef ---

	LLVMModuleCreateWithNameInContext :: proc(ModuleID: cstring, C: LLVMContextRef) -> LLVMModuleRef ---
	LLVMDisposeModule :: proc(M: LLVMModuleRef) ---
	LLVMSetTarget :: proc(M: LLVMModuleRef, Triple: cstring) ---
	LLVMPrintModuleToFile :: proc(M: LLVMModuleRef, Filename: cstring, ErrorMessage: ^cstring) -> LLVMBool ---
	LLVMPrintModuleToString :: proc(M: LLVMModuleRef) -> cstring ---
	LLVMAddFunction :: proc(M: LLVMModuleRef, Name: cstring, FunctionTy: LLVMTypeRef) -> LLVMValueRef ---

	LLVMInt8TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt16TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt32TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt64TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMFunctionType :: proc(ReturnType: LLVMTypeRef, ParamTypes: [^]LLVMTypeRef, ParamCount: u32, IsVarArg: LLVMBool) -> LLVMTypeRef ---
	LLVMStructTypeInContext :: proc(C: LLVMContextRef, ElementTypes: [^]LLVMTypeRef, ElementCount: u32, Packed: LLVMBool) -> LLVMTypeRef ---
	LLVMArrayType2 :: proc(ElementType: LLVMTypeRef, ElementCount: u64) -> LLVMTypeRef ---
	LLVMPointerTypeInContext :: proc(C: LLVMContextRef, AddressSpace: u32) -> LLVMTypeRef ---
	LLVMVoidTypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---

	LLVMConstNull :: proc(Ty: LLVMTypeRef) -> LLVMValueRef ---
	LLVMConstInt :: proc(IntTy: LLVMTypeRef, N: u64, SignExtend: LLVMBool) -> LLVMValueRef ---
	LLVMConstStructInContext :: proc(C: LLVMContextRef, ConstantVals: [^]LLVMValueRef, Count: u32, Packed: LLVMBool) -> LLVMValueRef ---
	LLVMConstArray2 :: proc(ElementTy: LLVMTypeRef, ConstantVals: [^]LLVMValueRef, Length: u64) -> LLVMValueRef ---

	LLVMSetLinkage :: proc(Global: LLVMValueRef, Linkage: LLVMLinkage) ---
	LLVMSetUnnamedAddress :: proc(Global: LLVMValueRef, UnnamedAddr: LLVMUnnamedAddr) ---
	LLVMSetAlignment :: proc(V: LLVMValueRef, Bytes: u32) ---
	LLVMAddGlobal :: proc(M: LLVMModuleRef, Ty: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMSetInitializer :: proc(GlobalVar: LLVMValueRef, ConstantVal: LLVMValueRef) ---
	LLVMSetGlobalConstant :: proc(GlobalVar: LLVMValueRef, IsConstant: LLVMBool) ---

	LLVMAddAttributeAtIndex :: proc(F: LLVMValueRef, Idx: LLVMAttributeIndex, A: LLVMAttributeRef) ---
	LLVMAppendBasicBlockInContext :: proc(C: LLVMContextRef, Fn: LLVMValueRef, Name: cstring) -> LLVMBasicBlockRef ---

	LLVMCreateBuilderInContext :: proc(C: LLVMContextRef) -> LLVMBuilderRef ---
	LLVMPositionBuilderAtEnd :: proc(Builder: LLVMBuilderRef, Block: LLVMBasicBlockRef) ---
	LLVMDisposeBuilder :: proc(Builder: LLVMBuilderRef) ---
	// The header leaves the builder and type parameters of these three unnamed.
	LLVMBuildRetVoid :: proc(B: LLVMBuilderRef) -> LLVMValueRef ---
	LLVMBuildRet :: proc(B: LLVMBuilderRef, V: LLVMValueRef) -> LLVMValueRef ---
	LLVMBuildCall2 :: proc(B: LLVMBuilderRef, Ty: LLVMTypeRef, Fn: LLVMValueRef, Args: [^]LLVMValueRef, NumArgs: u32, Name: cstring) -> LLVMValueRef ---

	LLVMGetBufferSize :: proc(MemBuf: LLVMMemoryBufferRef) -> uint ---
	LLVMDisposeMemoryBuffer :: proc(MemBuf: LLVMMemoryBufferRef) ---
}
