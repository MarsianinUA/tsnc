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

Errors: emit returns an Error value, like every infrastructure failure in tsnc. When LLVM explains a
failure, emit logs the text at error level through context.logger.
*/
package codegen

import "base:runtime"
import "core:log"
import "core:strings"

import "../ir"
import "../llvm"
import "../target"

// Optimization values are lowercase because they are the values of `tsnc -o:`: core:flags matches
// them against the command line by exact name, and Odin's `-o:` spells them the same way.
Optimization :: enum u8 {
	none, // pipeline default<O0>, machine code level None
	speed, // pipeline default<O2>, machine code level Default
	aggressive, // pipeline default<O3>, machine code level Aggressive
}

Artifact :: enum u8 {
	Object, // native object file for the target
	LLVM_IR, // textual LLVM IR, for -emit-llvm
}

Error :: enum u8 {
	None,
	Unsupported_Target, // no target.SPECS row, or LLVM has no backend for the triple
	Invalid_Module, // the LLVM verifier rejected the module: a codegen bug
	Passes_Failed, // LLVMRunPasses rejected the pipeline: a codegen bug
	Write_Failed, // the artifact could not be written to the path
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
) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if !target.supported(build_target) {
		return .Unsupported_Target
	}
	triple := target.SPECS[build_target].triple

	// --- Target machine for the triple.
	backend: llvm.LLVMTargetRef
	lookup_message: cstring
	lookup_failed := bool(llvm.LLVMGetTargetFromTriple(triple, &backend, &lookup_message))
	defer llvm.LLVMDisposeMessage(lookup_message)
	if lookup_failed {
		log.errorf("codegen: no LLVM backend for %s: %s", triple, lookup_message)
		return .Unsupported_Target
	}
	// direct: the generic CPU of the triple; a cpu column in target.SPECS when benchmarks ask for
	// tuned code.
	machine := llvm.LLVMCreateTargetMachine(
		backend,
		triple,
		"",
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
	// Before the verifier: a module abandoned halfway is not worth a verifier report.
	if build_error := build_module(ctx, module, program, unit); build_error != .None {
		return build_error
	}

	// --- Verify before the passes, so a codegen bug is reported against the module it made.
	verify_message: cstring
	broken := bool(llvm.LLVMVerifyModule(module, .LLVMReturnStatusAction, &verify_message))
	defer llvm.LLVMDisposeMessage(verify_message)
	if broken {
		log.errorf("codegen: the LLVM verifier rejected the module:\n%s", verify_message)
		return .Invalid_Module
	}

	// --- Pass pipeline of the level.
	options := llvm.LLVMCreatePassBuilderOptions()
	defer llvm.LLVMDisposePassBuilderOptions(options)
	if pass_error := llvm.LLVMRunPasses(module, PIPELINES[level], machine, options);
	   pass_error != nil {
		pass_message := llvm.LLVMGetErrorMessage(pass_error)
		defer llvm.LLVMDisposeErrorMessage(pass_message)
		log.errorf("codegen: pipeline %s: %s", PIPELINES[level], pass_message)
		return .Passes_Failed
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
		log.errorf("codegen: cannot write %s: %s", path, write_message)
		return .Write_Failed
	}
	return .None
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
