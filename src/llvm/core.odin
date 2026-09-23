package llvm

// Core.h

// The one import with LLVM_LINKER_FLAGS; see llvm.odin.
when true {
	@(ignore_duplicates, priority_index = -1, extra_linker_flags = LLVM_LINKER_FLAGS)
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

LLVMIntPredicate :: enum i32 {
	LLVMIntEQ  = 32,
	LLVMIntNE  = 33,
	LLVMIntUGT = 34,
	LLVMIntUGE = 35,
	LLVMIntULT = 36,
	LLVMIntULE = 37,
	LLVMIntSGT = 38,
	LLVMIntSGE = 39,
	LLVMIntSLT = 40,
	LLVMIntSLE = 41,
}

LLVMRealPredicate :: enum i32 {
	LLVMRealPredicateFalse = 0,
	LLVMRealOEQ            = 1,
	LLVMRealOGT            = 2,
	LLVMRealOGE            = 3,
	LLVMRealOLT            = 4,
	LLVMRealOLE            = 5,
	LLVMRealONE            = 6,
	LLVMRealORD            = 7,
	LLVMRealUNO            = 8,
	LLVMRealUEQ            = 9,
	LLVMRealUGT            = 10,
	LLVMRealUGE            = 11,
	LLVMRealULT            = 12,
	LLVMRealULE            = 13,
	LLVMRealUNE            = 14,
	LLVMRealPredicateTrue  = 15,
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

	LLVMInt1TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt8TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt16TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt32TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMInt64TypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMDoubleTypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---
	LLVMFunctionType :: proc(ReturnType: LLVMTypeRef, ParamTypes: [^]LLVMTypeRef, ParamCount: u32, IsVarArg: LLVMBool) -> LLVMTypeRef ---
	LLVMStructTypeInContext :: proc(C: LLVMContextRef, ElementTypes: [^]LLVMTypeRef, ElementCount: u32, Packed: LLVMBool) -> LLVMTypeRef ---
	LLVMStructCreateNamed :: proc(C: LLVMContextRef, Name: cstring) -> LLVMTypeRef ---
	LLVMStructSetBody :: proc(StructTy: LLVMTypeRef, ElementTypes: [^]LLVMTypeRef, ElementCount: u32, Packed: LLVMBool) ---
	LLVMArrayType2 :: proc(ElementType: LLVMTypeRef, ElementCount: u64) -> LLVMTypeRef ---
	LLVMPointerTypeInContext :: proc(C: LLVMContextRef, AddressSpace: u32) -> LLVMTypeRef ---
	LLVMVoidTypeInContext :: proc(C: LLVMContextRef) -> LLVMTypeRef ---

	LLVMConstNull :: proc(Ty: LLVMTypeRef) -> LLVMValueRef ---
	LLVMGetUndef :: proc(Ty: LLVMTypeRef) -> LLVMValueRef ---
	LLVMConstInt :: proc(IntTy: LLVMTypeRef, N: u64, SignExtend: LLVMBool) -> LLVMValueRef ---
	LLVMConstReal :: proc(RealTy: LLVMTypeRef, N: f64) -> LLVMValueRef ---
	LLVMConstStringInContext :: proc(C: LLVMContextRef, Str: [^]u8, Length: u32, DontNullTerminate: LLVMBool) -> LLVMValueRef ---
	LLVMConstStructInContext :: proc(C: LLVMContextRef, ConstantVals: [^]LLVMValueRef, Count: u32, Packed: LLVMBool) -> LLVMValueRef ---
	LLVMConstNamedStruct :: proc(StructTy: LLVMTypeRef, ConstantVals: [^]LLVMValueRef, Count: u32) -> LLVMValueRef ---
	LLVMConstArray2 :: proc(ElementTy: LLVMTypeRef, ConstantVals: [^]LLVMValueRef, Length: u64) -> LLVMValueRef ---

	// Intrinsics. LLVMLookupIntrinsicID answers 0 for a name this LLVM does not know, which is how
	// codegen decides between an intrinsic and a libm call. An overloaded intrinsic takes the types
	// it is overloaded on in ParamTypes, and both procedures mangle the name from them.
	LLVMLookupIntrinsicID :: proc(Name: [^]u8, NameLen: uint) -> u32 ---
	LLVMGetIntrinsicDeclaration :: proc(Mod: LLVMModuleRef, ID: u32, ParamTypes: [^]LLVMTypeRef, ParamCount: uint) -> LLVMValueRef ---
	LLVMIntrinsicGetType :: proc(Ctx: LLVMContextRef, ID: u32, ParamTypes: [^]LLVMTypeRef, ParamCount: uint) -> LLVMTypeRef ---

	LLVMSetLinkage :: proc(Global: LLVMValueRef, Linkage: LLVMLinkage) ---
	LLVMSetUnnamedAddress :: proc(Global: LLVMValueRef, UnnamedAddr: LLVMUnnamedAddr) ---
	LLVMSetAlignment :: proc(V: LLVMValueRef, Bytes: u32) ---
	LLVMAddGlobal :: proc(M: LLVMModuleRef, Ty: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMSetInitializer :: proc(GlobalVar: LLVMValueRef, ConstantVal: LLVMValueRef) ---
	LLVMSetGlobalConstant :: proc(GlobalVar: LLVMValueRef, IsConstant: LLVMBool) ---

	LLVMAddAttributeAtIndex :: proc(F: LLVMValueRef, Idx: LLVMAttributeIndex, A: LLVMAttributeRef) ---
	LLVMGetParam :: proc(Fn: LLVMValueRef, Index: u32) -> LLVMValueRef ---
	LLVMAppendBasicBlockInContext :: proc(C: LLVMContextRef, Fn: LLVMValueRef, Name: cstring) -> LLVMBasicBlockRef ---

	LLVMCreateBuilderInContext :: proc(C: LLVMContextRef) -> LLVMBuilderRef ---
	LLVMPositionBuilderAtEnd :: proc(Builder: LLVMBuilderRef, Block: LLVMBasicBlockRef) ---
	LLVMDisposeBuilder :: proc(Builder: LLVMBuilderRef) ---
	// The header leaves the builder and type parameters of these three unnamed.
	LLVMBuildRetVoid :: proc(B: LLVMBuilderRef) -> LLVMValueRef ---
	LLVMBuildRet :: proc(B: LLVMBuilderRef, V: LLVMValueRef) -> LLVMValueRef ---
	LLVMBuildCall2 :: proc(B: LLVMBuilderRef, Ty: LLVMTypeRef, Fn: LLVMValueRef, Args: [^]LLVMValueRef, NumArgs: u32, Name: cstring) -> LLVMValueRef ---
	LLVMBuildBr :: proc(B: LLVMBuilderRef, Dest: LLVMBasicBlockRef) -> LLVMValueRef ---
	LLVMBuildCondBr :: proc(B: LLVMBuilderRef, If: LLVMValueRef, Then: LLVMBasicBlockRef, Else: LLVMBasicBlockRef) -> LLVMValueRef ---
	LLVMBuildUnreachable :: proc(B: LLVMBuilderRef) -> LLVMValueRef ---

	LLVMBuildFAdd :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildFSub :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildFMul :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildFDiv :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildFRem :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildFNeg :: proc(B: LLVMBuilderRef, V: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildShl :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildLShr :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildAShr :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildAnd :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildOr :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildXor :: proc(B: LLVMBuilderRef, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildNot :: proc(B: LLVMBuilderRef, V: LLVMValueRef, Name: cstring) -> LLVMValueRef ---

	LLVMBuildICmp :: proc(B: LLVMBuilderRef, Op: LLVMIntPredicate, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildFCmp :: proc(B: LLVMBuilderRef, Op: LLVMRealPredicate, LHS: LLVMValueRef, RHS: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildPhi :: proc(B: LLVMBuilderRef, Ty: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMAddIncoming :: proc(PhiNode: LLVMValueRef, IncomingValues: [^]LLVMValueRef, IncomingBlocks: [^]LLVMBasicBlockRef, Count: u32) ---
	LLVMBuildSelect :: proc(B: LLVMBuilderRef, If: LLVMValueRef, Then: LLVMValueRef, Else: LLVMValueRef, Name: cstring) -> LLVMValueRef ---

	LLVMBuildAlloca :: proc(B: LLVMBuilderRef, Ty: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildLoad2 :: proc(B: LLVMBuilderRef, Ty: LLVMTypeRef, PointerVal: LLVMValueRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildStore :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, Ptr: LLVMValueRef) -> LLVMValueRef ---
	LLVMBuildExtractValue :: proc(B: LLVMBuilderRef, AggVal: LLVMValueRef, Index: u32, Name: cstring) -> LLVMValueRef ---
	LLVMBuildInsertValue :: proc(B: LLVMBuilderRef, AggVal: LLVMValueRef, EltVal: LLVMValueRef, Index: u32, Name: cstring) -> LLVMValueRef ---

	LLVMBuildTrunc :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildZExt :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildSIToFP :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildUIToFP :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildPtrToInt :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildIntToPtr :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---
	LLVMBuildBitCast :: proc(B: LLVMBuilderRef, Val: LLVMValueRef, DestTy: LLVMTypeRef, Name: cstring) -> LLVMValueRef ---

	LLVMGetBufferSize :: proc(MemBuf: LLVMMemoryBufferRef) -> uint ---
	LLVMDisposeMemoryBuffer :: proc(MemBuf: LLVMMemoryBufferRef) ---
}
