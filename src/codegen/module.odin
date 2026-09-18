package codegen

import "core:strings"
import "core:unicode/utf16"

import "../abi"
import "../llvm"

// HELLO_WORLD is the line the hello world stub prints. T4.4 removes both when the IR takes the
// stub's place.
HELLO_WORLD :: "Hello, world!"

// The LLVM type of a String_Cell is { i32, i32, i64, [N x i16] }: the two header words, the length,
// then N UTF-16 units. These pin the Odin layout the mapping relies on.
#assert(size_of(abi.Type_Table_ID) == 4)
#assert(size_of(abi.Cell_Flags) == 4)
#assert(offset_of(abi.String_Cell, length) == 8)
#assert(size_of(int) == 8)

// Runtime_Function is a declared runtime export: its signature, which LLVMBuildCall2 needs, and the
// function.
@(private)
Runtime_Function :: struct {
	signature: llvm.LLVMTypeRef,
	function:  llvm.LLVMValueRef,
}

// add_hello_world fills the module with the stub that stands in for the IR: tsnc_main passes a
// static cell with HELLO_WORLD to the runtime's string output.
@(private)
add_hello_world :: proc(ctx: llvm.LLVMContextRef, module: llvm.LLVMModuleRef) {
	runtime_functions := declare_runtime(ctx, module)
	text := add_string_cell(ctx, module, HELLO_WORLD)

	main_signature := llvm.LLVMFunctionType(llvm.LLVMVoidTypeInContext(ctx), nil, 0, false)
	main_function := llvm.LLVMAddFunction(module, abi.MAIN_SYMBOL, main_signature)
	builder := llvm.LLVMCreateBuilderInContext(ctx)
	defer llvm.LLVMDisposeBuilder(builder)
	llvm.LLVMPositionBuilderAtEnd(
		builder,
		llvm.LLVMAppendBasicBlockInContext(ctx, main_function, "entry"),
	)
	log_string := runtime_functions[.Log_String]
	args := [?]llvm.LLVMValueRef{text}
	llvm.LLVMBuildCall2(
		builder,
		log_string.signature,
		log_string.function,
		&args[0],
		len(args),
		"",
	)
	llvm.LLVMBuildRetVoid(builder)
}

// declare_runtime declares every export of abi.RUNTIME_EXPORTS, so generated code calls the runtime
// by the symbols and signatures the runtime exports.
@(private)
declare_runtime :: proc(
	ctx: llvm.LLVMContextRef,
	module: llvm.LLVMModuleRef,
) -> (
	functions: [abi.Runtime_Proc]Runtime_Function,
) {
	exports := abi.RUNTIME_EXPORTS
	for export, id in exports {
		params := make([]llvm.LLVMTypeRef, len(export.params), context.temp_allocator)
		for param, i in export.params {
			params[i] = c_type(ctx, param)
		}
		signature := llvm.LLVMFunctionType(
			c_type(ctx, export.result),
			raw_data(params),
			u32(len(params)),
			false,
		)
		symbol := strings.clone_to_cstring(export.symbol, context.temp_allocator)
		functions[id] = {signature, llvm.LLVMAddFunction(module, symbol, signature)}
	}
	return
}

@(private)
c_type :: proc(ctx: llvm.LLVMContextRef, kind: abi.C_Type) -> llvm.LLVMTypeRef {
	switch kind {
	case .Void:
		return llvm.LLVMVoidTypeInContext(ctx)
	case .Ptr:
		return llvm.LLVMPointerTypeInContext(ctx, 0)
	}
	unreachable()
}

// add_string_cell adds a String_Cell holding text as UTF-16 and returns its global. The cell is
// constant: it lives in read-only data, and the GC never marks it (see abi).
@(private)
add_string_cell :: proc(
	ctx: llvm.LLVMContextRef,
	module: llvm.LLVMModuleRef,
	text: string,
) -> llvm.LLVMValueRef {
	// UTF-8 never takes fewer bytes than UTF-16 takes units, so len(text) units are enough.
	units := make([]u16, len(text), context.temp_allocator)
	units = units[:utf16.encode_string(units, text)]

	i16_type := llvm.LLVMInt16TypeInContext(ctx)
	unit_values := make([]llvm.LLVMValueRef, len(units), context.temp_allocator)
	for u, i in units {
		unit_values[i] = llvm.LLVMConstInt(i16_type, u64(u), false)
	}

	i32_type := llvm.LLVMInt32TypeInContext(ctx)
	i64_type := llvm.LLVMInt64TypeInContext(ctx)
	field_types := [?]llvm.LLVMTypeRef {
		i32_type,
		i32_type,
		i64_type,
		llvm.LLVMArrayType2(i16_type, u64(len(units))),
	}
	fields := [?]llvm.LLVMValueRef {
		llvm.LLVMConstInt(i32_type, u64(abi.Builtin_Table.String), false), // header.type_table
		llvm.LLVMConstInt(i32_type, 0, false), // header.flags: none
		llvm.LLVMConstInt(i64_type, u64(len(units)), false), // length
		llvm.LLVMConstArray2(i16_type, raw_data(unit_values), u64(len(unit_values))), // units
	}
	cell_type := llvm.LLVMStructTypeInContext(ctx, &field_types[0], len(field_types), false)
	cell := llvm.LLVMAddGlobal(module, cell_type, "str")
	llvm.LLVMSetInitializer(
		cell,
		llvm.LLVMConstStructInContext(ctx, &fields[0], len(fields), false),
	)
	llvm.LLVMSetGlobalConstant(cell, true)
	llvm.LLVMSetLinkage(cell, .LLVMPrivateLinkage)
	llvm.LLVMSetUnnamedAddress(cell, .LLVMGlobalUnnamedAddr)
	llvm.LLVMSetAlignment(cell, align_of(abi.String_Cell))
	return cell
}
