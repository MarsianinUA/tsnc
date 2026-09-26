package codegen

import "../abi"
import "../ir"
import "../llvm"

/*
One case per variant of ir.Variant, in the order the union declares them, so this file and
src/ir/instructions.odin read side by side. The instruction set is closed: a new variant there is a
new case here.

A cell is addressed in bytes: a field and the length of an array or a string sit at the offsets abi
gives them, and an element is a slot of its kind's storage type in the buffer the array points at.
*/
@(private)
build_instruction :: proc(m: ^Module, body: ^Body, value: ir.Value_ID) {
	instruction := body.func.values[value]
	switch v in instruction.variant {
	case ir.Unreachable:
		llvm.LLVMBuildUnreachable(m.builder)

	case ir.Param:
		index := param_index(body.func.params, int(v.index))
		type := body.func.params[v.index]
		if param_words(type) == 2 {
			tag := llvm.LLVMGetParam(body.function, index)
			payload := llvm.LLVMGetParam(body.function, index + 1)
			body.values[value] = tagged_words(m, tag, payload)
		} else {
			body.values[value] = from_storage(m, llvm.LLVMGetParam(body.function, index), type)
		}

	case ir.Const_Number:
		// The bits as lower computed them: -0, NaN and the infinities are all reachable.
		body.values[value] = llvm.LLVMConstReal(m.types.double, v.value)

	case ir.Const_Bool:
		body.values[value] = llvm.LLVMConstInt(m.types.int1, 1 if v.value else 0, false)

	case ir.Const_Undefined:
		body.values[value] = const_tagged(m, .Undefined)

	case ir.Const_Null:
		if instruction.type == ir.TAGGED {
			body.values[value] = const_tagged(m, .Null)
		} else {
			body.values[value] = llvm.LLVMConstNull(m.types.ptr)
		}

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
		row := v.table if v.table != ir.NO_LAYOUT else v.layout
		args := [?]llvm.LLVMValueRef{table_word(m, row)}
		body.values[value] = call_runtime(m, .Alloc, args[:])

	case ir.New_Array:
		args := [?]llvm.LLVMValueRef{table_word(m, v.layout), body.values[v.length]}
		body.values[value] = call_runtime(m, .Array_New, args[:])

	case ir.Field_Load:
		address := field_address(m, body, v.cell, v.field)
		stored := llvm.LLVMBuildLoad2(m.builder, storage_type(m, instruction.type), address, "")
		body.values[value] = from_storage(m, stored, instruction.type)

	case ir.Field_Store:
		store(m, body, v.value, field_address(m, body, v.cell, v.field))

	case ir.Field_Store_Ref:
		store(m, body, v.value, field_address(m, body, v.cell, v.field))

	case ir.Length:
		body.values[value] = build_length(m, body.values[v.value])

	case ir.Bounds_Check:
		body.values[value] = build_bounds_check(m, body, v)

	case ir.Element_Load:
		address := element_address(m, body, v.array, v.index)
		stored := llvm.LLVMBuildLoad2(m.builder, storage_type(m, instruction.type), address, "")
		body.values[value] = from_storage(m, stored, instruction.type)

	case ir.Element_Store:
		store(m, body, v.value, element_address(m, body, v.array, v.index))

	case ir.Element_Store_Ref:
		store(m, body, v.value, element_address(m, body, v.array, v.index))

	case ir.Layout_Test:
		body.values[value] = build_layout_test(m, body.values[v.cell], v.layout)

	case ir.Tag_Test:
		body.values[value] = build_tag_test(m, body.values[v.value], v.tags)

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

	case ir.Env:
		body.values[value] = llvm.LLVMGetParam(body.function, 0)

	case ir.Func_Ref:
		body.values[value] = static_closure(m, v.func)

	case ir.Make_Closure:
		// The cell comes zero filled, so a function with no environment leaves that word null.
		table := [?]llvm.LLVMValueRef {
			llvm.LLVMConstInt(m.types.int64, u64(abi.Builtin_Table.Closure), false),
		}
		cell := call_runtime(m, .Alloc, table[:])
		code := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, code)))
		llvm.LLVMBuildStore(m.builder, m.funcs[v.func].function, code)
		if v.env != ir.NO_VALUE {
			env := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, env)))
			llvm.LLVMBuildStore(m.builder, body.values[v.env], env)
		}
		info := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, info)))
		llvm.LLVMBuildStore(m.builder, function_info(m, v.func), info)
		body.values[value] = cell

	case ir.Call:
		// A direct call names a function with no environment, which takes a null one.
		callee := m.funcs[v.func]
		env := llvm.LLVMConstNull(m.types.ptr)
		result := call_function(m, body, callee.signature, callee.function, env, v.args)
		if instruction.type != ir.VOID {
			body.values[value] = from_storage(m, result, instruction.type)
		}

	case ir.Call_Closure:
		cell := body.values[v.callee]
		code_address := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, code)))
		code := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, code_address, "")
		env_address := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, env)))
		env := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, env_address, "")
		params := make([]ir.Type, len(v.args), context.temp_allocator)
		for arg, i in v.args {
			params[i] = body.func.values[arg].type
		}
		signature := closure_signature(m, params, instruction.type)
		result := call_function(m, body, signature, code, env, v.args)
		if instruction.type != ir.VOID {
			body.values[value] = from_storage(m, result, instruction.type)
		}

	case ir.Call_Runtime:
		exports := abi.RUNTIME_EXPORTS
		export := exports[v.export]
		callee := m.runtime[v.export]
		args := make([dynamic]llvm.LLVMValueRef, context.temp_allocator)
		if export.result == .Tagged {
			append(&args, body.result_slot)
		}
		for param, i in export.params {
			if param == .Rest {
				address, count := pass_rest(m, body, v.args[i:])
				append(&args, address, count)
				break
			}
			// The verifier holds each argument to the C type of its parameter (ir.c_type_fits).
			append_argument(m, &args, body.values[v.args[i]], body.func.values[v.args[i]].type)
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
			llvm.LLVMBuildRet(m.builder, to_storage(m, body.values[v.value], body.func.result))
		}

	case ir.Fail:
		build_fail(m, v.site)
	}
}

// build_fail ends the block: tsnc_fail never returns.
@(private)
build_fail :: proc(m: ^Module, site: ir.Fail_Site_ID) {
	args := [?]llvm.LLVMValueRef{m.fail_sites[site]}
	call_runtime(m, .Fail, args[:])
	llvm.LLVMBuildUnreachable(m.builder)
}

// call_function passes the environment, then each argument the way closure_signature takes it.
@(private)
call_function :: proc(
	m: ^Module,
	body: ^Body,
	signature: llvm.LLVMTypeRef,
	function, env: llvm.LLVMValueRef,
	args: []ir.Value_ID,
) -> llvm.LLVMValueRef {
	values := make([dynamic]llvm.LLVMValueRef, 0, 1 + 2 * len(args), context.temp_allocator)
	append(&values, env)
	for arg in args {
		append_argument(m, &values, body.values[arg], body.func.values[arg].type)
	}
	return llvm.LLVMBuildCall2(
		m.builder,
		signature,
		function,
		raw_data(values),
		u32(len(values)),
		"",
	)
}

// append_argument passes a value of the IR type the one way every call takes it, into the runtime
// and into a function of the program alike: a boolean widened to i64 and a tagged value split into
// its param_words.
@(private)
append_argument :: proc(
	m: ^Module,
	args: ^[dynamic]llvm.LLVMValueRef,
	value: llvm.LLVMValueRef,
	type: ir.Type,
) {
	if param_words(type) == 2 {
		tag := llvm.LLVMBuildExtractValue(m.builder, value, 0, "")
		payload := llvm.LLVMBuildExtractValue(m.builder, value, 1, "")
		append(args, tag, payload)
		return
	}
	append(args, to_storage(m, value, type))
}

// call_runtime passes the arguments as they stand: the caller has spelled each in the C type its
// row declares.
@(private)
call_runtime :: proc(
	m: ^Module,
	export: abi.Runtime_Proc,
	args: []llvm.LLVMValueRef,
) -> llvm.LLVMValueRef {
	callee := m.runtime[export]
	return llvm.LLVMBuildCall2(
		m.builder,
		callee.signature,
		callee.function,
		raw_data(args),
		u32(len(args)),
		"",
	)
}

// table_word is the abi.C_Type.Table argument that names a layout's type table.
@(private)
table_word :: proc(m: ^Module, layout: ir.Layout_ID) -> llvm.LLVMValueRef {
	return llvm.LLVMConstInt(m.types.int64, u64(ir.table_id(layout)), false)
}

@(private)
byte_offset :: proc(m: ^Module, pointer: llvm.LLVMValueRef, offset: int) -> llvm.LLVMValueRef {
	bytes := llvm.LLVMConstInt(m.types.int64, u64(offset), false)
	return llvm.LLVMBuildInBoundsGEP2(m.builder, m.types.int8, pointer, &bytes, 1, "")
}

// field_address reads the offset from the layout of the cell's own type, which is the layout whose
// fields the index counts in.
@(private)
field_address :: proc(
	m: ^Module,
	body: ^Body,
	cell: ir.Value_ID,
	field: i32,
) -> llvm.LLVMValueRef {
	layout := body.func.values[cell].type.layout
	return byte_offset(m, body.values[cell], m.program.layouts[layout].fields[field].offset)
}

// element_address converts an index a bounds check answered, so the conversion is never poison.
@(private)
element_address :: proc(m: ^Module, body: ^Body, array, index: ir.Value_ID) -> llvm.LLVMValueRef {
	kind := m.program.layouts[body.func.values[array].type.layout].element
	pointer := byte_offset(m, body.values[array], int(offset_of(abi.Array_Cell, elements)))
	elements := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, pointer, "")
	position := llvm.LLVMBuildFPToSI(m.builder, body.values[index], m.types.int64, "")
	return llvm.LLVMBuildInBoundsGEP2(m.builder, slot_type(m, kind), elements, &position, 1, "")
}

@(private)
store :: proc(m: ^Module, body: ^Body, value: ir.Value_ID, address: llvm.LLVMValueRef) {
	stored := to_storage(m, body.values[value], body.func.values[value].type)
	llvm.LLVMBuildStore(m.builder, stored, address)
}

// build_length answers the length of a string or an array, which abi puts at one offset in both.
@(private)
build_length :: proc(m: ^Module, cell: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	#assert(offset_of(abi.Array_Cell, length) == offset_of(abi.String_Cell, length))
	pointer := byte_offset(m, cell, int(offset_of(abi.String_Cell, length)))
	length := llvm.LLVMBuildLoad2(m.builder, m.types.int64, pointer, "")
	return llvm.LLVMBuildSIToFP(m.builder, length, m.types.double, "")
}

// build_bounds_check splits the block: each failure gets a block of its own, and the code after
// the check goes on in a third, where the builder is left. An index that equals its truncation is an
// integer, which NaN is not; an infinity passes that test and fails the range.
@(private)
build_bounds_check :: proc(m: ^Module, body: ^Body, v: ir.Bounds_Check) -> llvm.LLVMValueRef {
	index := body.values[v.index]
	length := build_length(m, body.values[v.array])
	argument := [?]llvm.LLVMValueRef{index}
	whole := build_number_call(m, .Trunc, argument[:])
	is_integer := llvm.LLVMBuildFCmp(m.builder, .LLVMRealOEQ, index, whole, "")

	integer := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	not_integer := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	inside := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	outside := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	llvm.LLVMBuildCondBr(m.builder, is_integer, integer, not_integer)

	llvm.LLVMPositionBuilderAtEnd(m.builder, not_integer)
	build_fail(m, v.not_integer)

	llvm.LLVMPositionBuilderAtEnd(m.builder, integer)
	zero := llvm.LLVMConstReal(m.types.double, 0)
	from_start := llvm.LLVMBuildFCmp(m.builder, .LLVMRealOGE, index, zero, "")
	before_end := llvm.LLVMBuildFCmp(m.builder, .LLVMRealOLT, index, length, "")
	in_range := llvm.LLVMBuildAnd(m.builder, from_start, before_end, "")
	llvm.LLVMBuildCondBr(m.builder, in_range, inside, outside)

	llvm.LLVMPositionBuilderAtEnd(m.builder, outside)
	build_fail(m, v.out_of_range)

	llvm.LLVMPositionBuilderAtEnd(m.builder, inside)
	return index
}

// build_layout_test compares the table the header names with every row whose base is the layout: a
// cell names its own print order, which may be the layout's own row or one that reorders it.
@(private)
build_layout_test :: proc(
	m: ^Module,
	cell: llvm.LLVMValueRef,
	layout: ir.Layout_ID,
) -> llvm.LLVMValueRef {
	#assert(offset_of(abi.Cell_Header, type_table) == 0)
	header := llvm.LLVMBuildLoad2(m.builder, m.types.int32, cell, "")
	answer := llvm.LLVMConstInt(m.types.int1, 0, false)
	for base, row in m.program.base {
		if base != layout {
			continue
		}
		table := llvm.LLVMConstInt(m.types.int32, u64(ir.table_id(ir.Layout_ID(row))), false)
		same := llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, header, table, "")
		answer = llvm.LLVMBuildOr(m.builder, answer, same, "")
	}
	return answer
}

// build_tag_test compares the tag with each tag of the set and ORs the answers; InstCombine turns a
// run of neighbours such as Undefined and Null into one unsigned comparison.
@(private)
build_tag_test :: proc(
	m: ^Module,
	tagged: llvm.LLVMValueRef,
	tags: ir.Tag_Set,
) -> llvm.LLVMValueRef {
	tag := llvm.LLVMBuildExtractValue(m.builder, tagged, 0, "")
	answer: llvm.LLVMValueRef
	for want in tags {
		constant := llvm.LLVMConstInt(m.types.int64, u64(want), false)
		same := llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, tag, constant, "")
		answer = same if answer == nil else llvm.LLVMBuildOr(m.builder, answer, same, "")
	}
	if answer == nil {
		return llvm.LLVMConstInt(m.types.int1, 0, false)
	}
	return answer
}

// slot_type is how a slot of this kind sits in memory, which is storage_type of what it holds.
@(private)
slot_type :: proc(m: ^Module, kind: abi.Slot_Kind) -> llvm.LLVMTypeRef {
	switch kind {
	case .Number:
		return m.types.double
	case .Boolean:
		return m.types.int64
	case .Ref:
		return m.types.ptr
	case .Tagged:
		return m.types.tagged
	}
	unreachable()
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

// pass_rest stores the values into the function's rest slot and answers the two arguments a Rest
// parameter takes: their address, null when there are none, and their count.
@(private)
pass_rest :: proc(
	m: ^Module,
	body: ^Body,
	values: []ir.Value_ID,
) -> (
	address: llvm.LLVMValueRef,
	count: llvm.LLVMValueRef,
) {
	count = llvm.LLVMConstInt(m.types.int64, u64(len(values)), false)
	if len(values) == 0 {
		return llvm.LLVMConstNull(m.types.ptr), count
	}
	for value, i in values {
		index := llvm.LLVMConstInt(m.types.int64, u64(i), false)
		slot := llvm.LLVMBuildInBoundsGEP2(
			m.builder,
			m.types.tagged,
			body.rest_slot,
			&index,
			1,
			"",
		)
		llvm.LLVMBuildStore(m.builder, body.values[value], slot)
	}
	return body.rest_slot, count
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
	return tagged_words(m, llvm.LLVMConstInt(m.types.int64, u64(tag), false), payload)
}

@(private)
tagged_words :: proc(m: ^Module, tag, payload: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	tagged := llvm.LLVMBuildInsertValue(m.builder, llvm.LLVMGetUndef(m.types.tagged), tag, 0, "")
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
