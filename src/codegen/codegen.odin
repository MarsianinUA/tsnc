/*
IR to machine code through LLVM. One emit call builds one LLVM module for the functions of one
codegen unit and writes it as an object file or as textual LLVM IR.

The translation is one to one: a number is a double, a boolean an i1, a tagged value the two words
of abi.Tagged, and every reference an opaque pointer. Each IR block becomes an LLVM block and each
instruction one or a few LLVM instructions. codegen reads the program and never changes it, and it
knows nothing of TypeScript: the closed instruction set of package ir is the whole contract.

The program is expected to have passed ir.verify. codegen relies on what the verifier promises -
one terminator per block, definitions before uses, exact operand types - and does not check again.

LLVM state: init_global_options changes process-global LLVM state, so it runs once, before any other
thread uses LLVM; driver calls it before its thread pool. Everything else belongs to one call: emit
creates and disposes its own context, module and target machine, so calls on different threads
share nothing.

Memory: emit owns nothing that outlives the call. Scratch goes to context.temp_allocator behind a
temp guard, and the LLVM handles are disposed on the way out.

Errors: emit returns an Error, which driver translates as it does link's.
*/
package codegen

import "base:runtime"
import "core:strings"

import "../ir"
import "../llvm"
import "../target"

// Optimization values are lowercase because they are the values of `tsnc -o:`: core:flags matches
// them against the command line by exact name, and Odin's `-o:` spells them the same way.
Optimization :: enum u8 {
	none,
	speed,
	aggressive,
}

Artifact :: enum u8 {
	Object, // native object file for the target
	LLVM_IR, // textual LLVM IR, for -emit-llvm
}

Error_Kind :: enum u8 {
	None,
	Unsupported_Target, // no target.SPECS row, or LLVM has no backend for the triple
	Invalid_Module, // the LLVM verifier rejected the module: a codegen bug
	Passes_Failed, // LLVMRunPasses rejected the pipeline: a codegen bug
	Write_Failed, // the artifact could not be written to the path
}

Error :: struct {
	kind:   Error_Kind,
	detail: string, // LLVM's message, allocated with emit's allocator; empty when LLVM gave none
}

// init_global_options passes -disable-lsr to turn off loop strength reduction, which creates
// pointers into the middle of objects that a conservative GC stack scan may miss (requirements 6).
// The backends it registers and the options are process-global: call it once, before any other
// thread uses LLVM.
init_global_options :: proc "contextless" () {
	llvm.LLVMInitializeX86TargetInfo()
	llvm.LLVMInitializeX86Target()
	llvm.LLVMInitializeX86TargetMC()
	llvm.LLVMInitializeX86AsmPrinter()

	llvm.LLVMInitializeAArch64TargetInfo()
	llvm.LLVMInitializeAArch64Target()
	llvm.LLVMInitializeAArch64TargetMC()
	llvm.LLVMInitializeAArch64AsmPrinter()

	args := [?]cstring{"tsnc", "-disable-lsr"}
	llvm.LLVMParseCommandLineOptions(len(args), &args[0], "")
}

// emit needs init_global_options to have run and the program to have passed ir.verify.
@(require_results)
emit :: proc(
	program: ^ir.Program_IR,
	unit: ir.Unit,
	build_target: target.Target,
	level: Optimization,
	artifact: Artifact,
	path: string,
	allocator := context.allocator,
) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	if !target.supported(build_target) {
		return {kind = .Unsupported_Target}
	}
	triple := target.SPECS[build_target].triple

	// --- Target machine for the triple.
	backend: llvm.LLVMTargetRef
	lookup_message: cstring
	lookup_failed := bool(llvm.LLVMGetTargetFromTriple(triple, &backend, &lookup_message))
	defer llvm.LLVMDisposeMessage(lookup_message)
	if lookup_failed {
		detail := strings.concatenate({string(triple), ": ", string(lookup_message)}, allocator)
		return {.Unsupported_Target, detail}
	}
	machine := llvm.LLVMCreateTargetMachine(
		backend,
		triple,
		target.SPECS[build_target].cpu,
		"",
		MACHINE_CODE_LEVELS[level],
		.LLVMRelocDefault,
		.LLVMCodeModelDefault,
	)
	defer llvm.LLVMDisposeTargetMachine(machine)

	// --- Module: target, data layout, contents.
	ctx := llvm.LLVMContextCreate()
	defer llvm.LLVMContextDispose(ctx)
	module := llvm.LLVMModuleCreateWithNameInContext("tsnc", ctx)
	defer llvm.LLVMDisposeModule(module)
	llvm.LLVMSetTarget(module, triple)
	data_layout := llvm.LLVMCreateTargetDataLayout(machine)
	llvm.LLVMSetModuleDataLayout(module, data_layout)
	llvm.LLVMDisposeTargetData(data_layout)
	build_module(ctx, module, program, unit)

	// --- Verify before the passes, so a codegen bug is reported against the module it made.
	verify_message: cstring
	broken := bool(llvm.LLVMVerifyModule(module, .LLVMReturnStatusAction, &verify_message))
	defer llvm.LLVMDisposeMessage(verify_message)
	if broken {
		return {.Invalid_Module, strings.clone_from_cstring(verify_message, allocator)}
	}

	// --- Pass pipeline of the level.
	options := llvm.LLVMCreatePassBuilderOptions()
	defer llvm.LLVMDisposePassBuilderOptions(options)
	if pass_error := llvm.LLVMRunPasses(module, PIPELINES[level], machine, options);
	   pass_error != nil {
		pass_message := llvm.LLVMGetErrorMessage(pass_error)
		defer llvm.LLVMDisposeErrorMessage(pass_message)
		pipeline := string(PIPELINES[level])
		detail := strings.concatenate({pipeline, ": ", string(pass_message)}, allocator)
		return {.Passes_Failed, detail}
	}

	// --- Write the artifact.
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	write_message: cstring
	write_failed: bool
	switch artifact {
	case .Object:
		write_failed = bool(
			llvm.LLVMTargetMachineEmitToFile(
				machine,
				module,
				c_path,
				.LLVMObjectFile,
				&write_message,
			),
		)
	case .LLVM_IR:
		write_failed = bool(llvm.LLVMPrintModuleToFile(module, c_path, &write_message))
	}
	defer llvm.LLVMDisposeMessage(write_message)
	if write_failed {
		return {.Write_Failed, strings.clone_from_cstring(write_message, allocator)}
	}
	return {}
}

// Clang uses the same pipelines and machine code levels for -O0, -O2 and -O3.

@(private, rodata)
PIPELINES := [Optimization]cstring {
	.none       = "default<O0>",
	.speed      = "default<O2>",
	.aggressive = "default<O3>",
}

@(private, rodata)
MACHINE_CODE_LEVELS := [Optimization]llvm.LLVMCodeGenOptLevel {
	.none       = .LLVMCodeGenLevelNone,
	.speed      = .LLVMCodeGenLevelDefault,
	.aggressive = .LLVMCodeGenLevelAggressive,
}
