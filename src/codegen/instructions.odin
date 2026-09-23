package codegen

import "../abi"
import "../ir"
import "../llvm"

/*
One case per variant of ir.Variant, in the order the union declares them, so this file and
src/ir/instructions.odin read side by side. The instruction set is closed: a new variant there is a
new case here.

The cases that report themselves unsupported are the ones whose runtime does not exist yet - a cell
to allocate, a field or an element to address, a closure to call. lower refuses every construct
that would build one (Not_Lowered, T2027), so no program reaches them; T5.7 and T5.8 fill them in
together with the collector and the closure convention.
*/
@(private)
build_instruction :: proc(m: ^Module, body: ^Body, value: ir.Value_ID) {
	instruction := body.func.values[value]
	switch v in instruction.variant {
	case ir.Unreachable:
		llvm.LLVMBuildUnreachable(m.builder)

	case ir.Param:
		// A function that captures takes its environment ahead of the TypeScript parameters.
		index := u32(v.index)
		if body.func.env != ir.NO_LAYOUT {
			index += 1
		}
		body.values[value] = llvm.LLVMGetParam(body.function, index)

	case ir.Const_Number:
		// The bits as lower computed them: -0, NaN and the infinities are all reachable.
		body.values[value] = llvm.LLVMConstReal(m.types.double, v.value)

	case ir.Const_Bool:
		body.values[value] = llvm.LLVMConstInt(m.types.int1, 1 if v.value else 0, false)

	case ir.Const_Undefined:
		body.values[value] = const_tagged(m, .Undefined)

	case ir.Const_Null:
		body.values[value] = const_tagged(m, .Null)

	case ir.Const_String:
		body.values[value] = m.string_cells[v.text]

	case ir.Binary:
		body.values[value] = build_binary(m, body, v)

	case ir.Unary:
		body.values[value] = build_unary(m, body.values[v.operand], v.op)

	case ir.Compare:
		body.values[value] = build_compare(m, body, v)

	case ir.Phi:
	// Created ahead of the other instructions of its block; its edges are patched afterwards.

	case ir.Alloc:
		unsupported(m, "alloc")

	case ir.Field_Load:
		unsupported(m, "field_load")

	case ir.Field_Store:
		unsupported(m, "field_store")

	case ir.Field_Store_Ref:
		unsupported(m, "field_store_ref")

	case ir.Bounds_Check:
		unsupported(m, "bounds_check")

	case ir.Element_Load:
		unsupported(m, "element_load")

	case ir.Element_Store:
		unsupported(m, "element_store")

	case ir.Element_Store_Ref:
		unsupported(m, "element_store_ref")

	case ir.Tag_Test:
		tag := llvm.LLVMBuildExtractValue(m.builder, body.values[v.value], 0, "")
		want := llvm.LLVMConstInt(m.types.int64, u64(v.tag), false)
		body.values[value] = llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, tag, want, "")

	case ir.Box:
		body.values[value] = build_box(m, body.values[v.value], body.func.values[v.value].type)

	case ir.Unbox:
		// No check: a tag_test, or a fail, came first.
		payload := llvm.LLVMBuildExtractValue(m.builder, body.values[v.value], 1, "")
		body.values[value] = build_unbox(m, payload, instruction.type)

	case ir.Global_Load:
		type := m.program.globals[v.global].type
		stored := llvm.LLVMBuildLoad2(m.builder, storage_type(m, type), m.globals[v.global], "")
		body.values[value] = from_storage(m, stored, type)

	case ir.Global_Store:
		type := m.program.globals[v.global].type
		stored := to_storage(m, body.values[v.value], type)
		llvm.LLVMBuildStore(m.builder, stored, m.globals[v.global])

	case ir.Call:
		// lower calls only functions that capture nothing; a closure goes through call_closure.
		assert(
			m.program.funcs[v.func].env == ir.NO_LAYOUT,
			"a direct call to a function with an environment",
		)
		callee := m.funcs[v.func]
		args := make([]llvm.LLVMValueRef, len(v.args), context.temp_allocator)
		for arg, i in v.args {
			args[i] = body.values[arg]
		}
		result := llvm.LLVMBuildCall2(
			m.builder,
			callee.signature,
			callee.function,
			raw_data(args),
			u32(len(args)),
			"",
		)
		if instruction.type != ir.VOID {
			body.values[value] = result
		}

	case ir.Call_Closure:
		unsupported(m, "call_closure")

	case ir.Call_Runtime:
		exports := abi.RUNTIME_EXPORTS
		export := exports[v.export]
		callee := m.runtime[v.export]
		args := make([dynamic]llvm.LLVMValueRef, context.temp_allocator)
		if export.result == .Tagged {
			append(&args, body.result_slot)
		}
		for arg, i in v.args {
			operand := body.values[arg]
			#partial switch export.params[i] {
			case .Boolean:
				append(&args, llvm.LLVMBuildZExt(m.builder, operand, m.types.int64, ""))
			case .Tagged:
				tag := llvm.LLVMBuildExtractValue(m.builder, operand, 0, "")
				payload := llvm.LLVMBuildExtractValue(m.builder, operand, 1, "")
				append(&args, tag, payload)
			case:
				append(&args, operand)
			}
		}
		result := llvm.LLVMBuildCall2(
			m.builder,
			callee.signature,
			callee.function,
			raw_data(args),
			u32(len(args)),
			"",
		)
		if instruction.type != ir.VOID {
			#partial switch export.result {
			case .Boolean:
				result = llvm.LLVMBuildTrunc(m.builder, result, m.types.int1, "")
			case .Tagged:
				result = llvm.LLVMBuildLoad2(m.builder, m.types.tagged, body.result_slot, "")
			}
			body.values[value] = result
		}

	case ir.Intrinsic:
		args := make([]llvm.LLVMValueRef, len(v.args), context.temp_allocator)
		for arg, i in v.args {
			args[i] = body.values[arg]
		}
		body.values[value] = build_number_call(m, v.op, args)

	case ir.Jump:
		llvm.LLVMBuildBr(m.builder, body.blocks[v.target])

	case ir.Branch:
		llvm.LLVMBuildCondBr(
			m.builder,
			body.values[v.condition],
			body.blocks[v.then_block],
			body.blocks[v.else_block],
		)

	case ir.Return:
		if v.value == ir.NO_VALUE {
			llvm.LLVMBuildRetVoid(m.builder)
		} else {
			llvm.LLVMBuildRet(m.builder, body.values[v.value])
		}

	case ir.Fail:
		fail := m.runtime[.Fail]
		args := [?]llvm.LLVMValueRef{m.fail_sites[v.site]}
		llvm.LLVMBuildCall2(m.builder, fail.signature, fail.function, &args[0], len(args), "")
		// tsnc_fail never returns, and fail ends its block in the IR.
		llvm.LLVMBuildUnreachable(m.builder)
	}
}

@(private)
build_unary :: proc(m: ^Module, operand: llvm.LLVMValueRef, op: ir.Unary_Op) -> llvm.LLVMValueRef {
	switch op {
	case .Negate:
		return llvm.LLVMBuildFNeg(m.builder, operand, "")
	case .Not:
		return llvm.LLVMBuildNot(m.builder, operand, "")
	case .Bit_Not:
		return build_bit_not(m, operand)
	}
	unreachable()
}

@(private)
build_compare :: proc(m: ^Module, body: ^Body, v: ir.Compare) -> llvm.LLVMValueRef {
	left, right := body.values[v.left], body.values[v.right]
	if body.func.values[v.left].type == ir.F64 {
		return llvm.LLVMBuildFCmp(m.builder, REAL_PREDICATES[v.op], left, right, "")
	}
	// The verifier keeps the ordered comparisons on numbers, so what reaches here is the equality
	// of two booleans, or of two references, which compare by address.
	predicate := llvm.LLVMIntPredicate.LLVMIntEQ if v.op == .Equal else .LLVMIntNE
	return llvm.LLVMBuildICmp(m.builder, predicate, left, right, "")
}

// IEEE everywhere, which is what === asks of numbers: ordered predicates, so NaN compares false,
// and -0 equals 0. Not_Equal is the unordered one, so NaN differs from everything, itself included.
@(private, rodata)
REAL_PREDICATES := [ir.Compare_Op]llvm.LLVMRealPredicate {
	.Less          = .LLVMRealOLT,
	.Less_Equal    = .LLVMRealOLE,
	.Greater       = .LLVMRealOGT,
	.Greater_Equal = .LLVMRealOGE,
	.Equal         = .LLVMRealOEQ,
	.Not_Equal     = .LLVMRealUNE,
}

// const_tagged is a tagged value with an empty payload: undefined and null carry nothing.
@(private)
const_tagged :: proc(m: ^Module, tag: abi.Tag) -> llvm.LLVMValueRef {
	words := [?]llvm.LLVMValueRef {
		llvm.LLVMConstInt(m.types.int64, u64(tag), false),
		llvm.LLVMConstInt(m.types.int64, 0, false),
	}
	return llvm.LLVMConstNamedStruct(m.types.tagged, &words[0], len(words))
}

@(private)
build_box :: proc(m: ^Module, value: llvm.LLVMValueRef, type: ir.Type) -> llvm.LLVMValueRef {
	tag: abi.Tag
	payload: llvm.LLVMValueRef
	switch type.kind {
	case .F64:
		tag = .Number
		payload = llvm.LLVMBuildBitCast(m.builder, value, m.types.int64, "")
	case .Bool:
		tag = .Boolean
		payload = llvm.LLVMBuildZExt(m.builder, value, m.types.int64, "")
	case .Str:
		tag = .String
		payload = llvm.LLVMBuildPtrToInt(m.builder, value, m.types.int64, "")
	case .Ref:
		// Objects and arrays share the tag; the type table of the cell tells them apart.
		tag = .Object
		payload = llvm.LLVMBuildPtrToInt(m.builder, value, m.types.int64, "")
	case .Closure:
		tag = .Function
		payload = llvm.LLVMBuildPtrToInt(m.builder, value, m.types.int64, "")
	case .Void, .Tagged:
		// The verifier keeps both out of box.
		unreachable()
	}
	tagged := llvm.LLVMBuildInsertValue(
		m.builder,
		llvm.LLVMGetUndef(m.types.tagged),
		llvm.LLVMConstInt(m.types.int64, u64(tag), false),
		0,
		"",
	)
	return llvm.LLVMBuildInsertValue(m.builder, tagged, payload, 1, "")
}

@(private)
build_unbox :: proc(m: ^Module, payload: llvm.LLVMValueRef, type: ir.Type) -> llvm.LLVMValueRef {
	switch type.kind {
	case .F64:
		return llvm.LLVMBuildBitCast(m.builder, payload, m.types.double, "")
	case .Bool:
		return llvm.LLVMBuildTrunc(m.builder, payload, m.types.int1, "")
	case .Str, .Ref, .Closure:
		return llvm.LLVMBuildIntToPtr(m.builder, payload, m.types.ptr, "")
	case .Void, .Tagged:
		// The verifier keeps both out of unbox.
		unreachable()
	}
	unreachable()
}

// to_storage and from_storage move a value between value_type and storage_type.
@(private)
to_storage :: proc(m: ^Module, value: llvm.LLVMValueRef, type: ir.Type) -> llvm.LLVMValueRef {
	if type.kind == .Bool {
		return llvm.LLVMBuildZExt(m.builder, value, m.types.int64, "")
	}
	return value
}

@(private)
from_storage :: proc(m: ^Module, value: llvm.LLVMValueRef, type: ir.Type) -> llvm.LLVMValueRef {
	if type.kind == .Bool {
		return llvm.LLVMBuildTrunc(m.builder, value, m.types.int1, "")
	}
	return value
}

// unsupported keeps only the first mnemonic: build_func stops there, and emit turns it into an
// error rather than a half built module.
@(private)
unsupported :: proc(m: ^Module, mnemonic: string) {
	if m.unsupported == "" {
		m.unsupported = mnemonic
	}
}
