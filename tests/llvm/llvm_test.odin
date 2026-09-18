package llvm_tests

import "core:log"
import "core:strings"
import "core:testing"

import "../../src/llvm"

@(test)
version_is_llvm_20 :: proc(t: ^testing.T) {
	major, minor, patch: u32
	llvm.LLVMGetVersion(&major, &minor, &patch)
	testing.expectf(t, major == 20, "linked LLVM %v.%v.%v, want 20.x", major, minor, patch)
}

@(test)
module_with_function_prints_as_text :: proc(t: ^testing.T) {
	ctx := llvm.LLVMContextCreate()
	defer llvm.LLVMContextDispose(ctx)
	module := llvm.LLVMModuleCreateWithNameInContext("answer", ctx)
	defer llvm.LLVMDisposeModule(module)
	add_answer_function(ctx, module)

	message: cstring
	broken := bool(llvm.LLVMVerifyModule(module, .LLVMReturnStatusAction, &message))
	defer llvm.LLVMDisposeMessage(message)
	testing.expectf(t, !broken, "verifier: %v", message)

	text := llvm.LLVMPrintModuleToString(module)
	defer llvm.LLVMDisposeMessage(text)
	testing.expectf(
		t,
		strings.contains(string(text), "define i32 @answer()"),
		"module text:\n%v",
		text,
	)
}

@(test)
verifier_rejects_block_without_terminator :: proc(t: ^testing.T) {
	ctx := llvm.LLVMContextCreate()
	defer llvm.LLVMContextDispose(ctx)
	module := llvm.LLVMModuleCreateWithNameInContext("broken", ctx)
	defer llvm.LLVMDisposeModule(module)
	function_type := llvm.LLVMFunctionType(llvm.LLVMVoidTypeInContext(ctx), nil, 0, false)
	function := llvm.LLVMAddFunction(module, "broken", function_type)
	llvm.LLVMAppendBasicBlockInContext(ctx, function, "entry")

	message: cstring
	broken := bool(llvm.LLVMVerifyModule(module, .LLVMReturnStatusAction, &message))
	defer llvm.LLVMDisposeMessage(message)
	testing.expect(t, broken, "the verifier accepted a block without a terminator")
	testing.expect(t, len(message) > 0, "the verifier gave no message")
}

@(test)
host_target_runs_passes_and_emits_object :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		llvm.LLVMInitializeX86TargetInfo()
		llvm.LLVMInitializeX86Target()
		llvm.LLVMInitializeX86TargetMC()
		llvm.LLVMInitializeX86AsmPrinter()
	} else when ODIN_ARCH == .arm64 {
		llvm.LLVMInitializeAArch64TargetInfo()
		llvm.LLVMInitializeAArch64Target()
		llvm.LLVMInitializeAArch64TargetMC()
		llvm.LLVMInitializeAArch64AsmPrinter()
	} else {
		#panic("the llvm tests know only the amd64 and arm64 hosts")
	}

	triple := llvm.LLVMGetDefaultTargetTriple()
	defer llvm.LLVMDisposeMessage(triple)
	target: llvm.LLVMTargetRef
	lookup_message: cstring
	lookup_failed := bool(llvm.LLVMGetTargetFromTriple(triple, &target, &lookup_message))
	defer llvm.LLVMDisposeMessage(lookup_message)
	if !testing.expectf(t, !lookup_failed, "target for %v: %v", triple, lookup_message) {
		return
	}
	machine := llvm.LLVMCreateTargetMachine(
		target,
		triple,
		"",
		"",
		.LLVMCodeGenLevelDefault,
		.LLVMRelocDefault,
		.LLVMCodeModelDefault,
	)
	defer llvm.LLVMDisposeTargetMachine(machine)

	ctx := llvm.LLVMContextCreate()
	defer llvm.LLVMContextDispose(ctx)
	module := llvm.LLVMModuleCreateWithNameInContext("answer", ctx)
	defer llvm.LLVMDisposeModule(module)
	llvm.LLVMSetTarget(module, triple)
	data_layout := llvm.LLVMCreateTargetDataLayout(machine)
	llvm.LLVMSetModuleDataLayout(module, data_layout)
	llvm.LLVMDisposeTargetData(data_layout)
	add_answer_function(ctx, module)

	options := llvm.LLVMCreatePassBuilderOptions()
	defer llvm.LLVMDisposePassBuilderOptions(options)
	if err := llvm.LLVMRunPasses(module, "default<O2>", machine, options); err != nil {
		err_text := llvm.LLVMGetErrorMessage(err)
		defer llvm.LLVMDisposeErrorMessage(err_text)
		log.errorf("LLVMRunPasses: %v", err_text)
		return
	}

	object: llvm.LLVMMemoryBufferRef
	emit_message: cstring
	emit_failed := bool(
		llvm.LLVMTargetMachineEmitToMemoryBuffer(
			machine,
			module,
			.LLVMObjectFile,
			&emit_message,
			&object,
		),
	)
	defer llvm.LLVMDisposeMessage(emit_message)
	if !testing.expectf(t, !emit_failed, "emit: %v", emit_message) {
		return
	}
	defer llvm.LLVMDisposeMemoryBuffer(object)
	testing.expect(t, llvm.LLVMGetBufferSize(object) > 0, "the object file is empty")
}

// Adds `define i32 @answer() { ret i32 42 }` to the module.
@(private = "file")
add_answer_function :: proc(ctx: llvm.LLVMContextRef, module: llvm.LLVMModuleRef) {
	i32_type := llvm.LLVMInt32TypeInContext(ctx)
	function := llvm.LLVMAddFunction(
		module,
		"answer",
		llvm.LLVMFunctionType(i32_type, nil, 0, false),
	)
	builder := llvm.LLVMCreateBuilderInContext(ctx)
	defer llvm.LLVMDisposeBuilder(builder)
	llvm.LLVMPositionBuilderAtEnd(
		builder,
		llvm.LLVMAppendBasicBlockInContext(ctx, function, "entry"),
	)
	llvm.LLVMBuildRet(builder, llvm.LLVMConstInt(i32_type, 42, false))
}
