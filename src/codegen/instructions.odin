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
		if ir.is_integer(instruction.type) {
			whole := u64(i64(v.value))
			body.values[value] = llvm.LLVMConstInt(value_type(m, instruction.type), whole, true)
		} else {
			// The bits as lower computed them: -0, NaN and the infinities are all reachable.
			body.values[value] = llvm.LLVMConstReal(m.types.double, v.value)
		}

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
		body.values[value] = build_binary(m, body, v, instruction.type)

	case ir.Unary:
		body.values[value] = build_unary(m, body, v, instruction.type)

	case ir.Compare:
		body.values[value] = build_compare(m, body, v)

	case ir.Phi:
	// Created ahead of the other instructions of its block; its edges are patched afterwards.

	case ir.Convert:
		body.values[value] = build_convert(m, body, v, instruction.type)

	case ir.Alloc:
		row := v.table if v.table != ir.NO_LAYOUT else v.layout
		if v.place == .Stack {
			body.values[value] = start_stack_cell(m, body, value, ir.table_id(row))
		} else {
			size, _ := ir.cell_size(m.program^, body.func, value)
			body.values[value] = build_alloc(m, body, ir.table_id(row), size)
		}

	case ir.New_Array:
		if v.place == .Stack {
			body.values[value] = build_stack_array(m, body, value, v)
		} else {
			args := [?]llvm.LLVMValueRef{table_word(m, v.layout), body.values[v.length]}
			body.values[value] = call_runtime(m, .Array_New, args[:])
		}

	case ir.Field_Load:
		address := field_address(m, body, v.cell, v.field)
		load := llvm.LLVMBuildLoad2(m.builder, storage_type(m, instruction.type), address, "")
		stored := mark(m, load, field_tag(m, body, v.cell, v.field))
		body.values[value] = from_storage(m, stored, instruction.type)

	case ir.Field_Store:
		address := field_address(m, body, v.cell, v.field)
		store(m, body, v.value, address, field_tag(m, body, v.cell, v.field))

	case ir.Field_Store_Ref:
		address := field_address(m, body, v.cell, v.field)
		store(m, body, v.value, address, field_tag(m, body, v.cell, v.field))

	case ir.Length:
		place := length_place(body.func.values[v.value].type)
		body.values[value] = build_length(m, body.values[v.value], place, instruction.type)

	case ir.Reserve:
		build_reserve(m, body, body.values[v.array])

	case ir.Set_Length:
		pointer := byte_offset(m, body.values[v.array], int(offset_of(abi.Array_Cell, length)))
		length := index_word(m, body, v.length)
		mark(m, llvm.LLVMBuildStore(m.builder, length, pointer), m.places[.Array_Length])

	case ir.Bounds_Check:
		if v.proved {
			body.values[value] = body.values[v.index]
		} else {
			body.values[value] = build_bounds_check(m, body, v)
		}

	case ir.Element_Load:
		address := element_address(m, body, v.array, v.index)
		load := llvm.LLVMBuildLoad2(m.builder, element_type(m, body, v.array), address, "")
		stored := mark(m, load, element_tag(m, body, v.array))
		body.values[value] = from_storage(m, stored, instruction.type)

	case ir.Element_Store:
		address := element_address(m, body, v.array, v.index)
		stored := body.values[v.value]
		if body.func.values[v.value].type.kind == .Bool {
			stored = llvm.LLVMBuildZExt(m.builder, stored, element_type(m, body, v.array), "")
		}
		mark(m, llvm.LLVMBuildStore(m.builder, stored, address), element_tag(m, body, v.array))

	case ir.Element_Store_Ref:
		address := element_address(m, body, v.array, v.index)
		store(m, body, v.value, address, element_tag(m, body, v.array))

	case ir.Unit_Load:
		units := byte_offset(m, body.values[v.text], int(offset_of(abi.String_Cell, units)))
		position := index_word(m, body, v.index)
		address := llvm.LLVMBuildInBoundsGEP2(m.builder, m.types.int16, units, &position, 1, "")
		load := llvm.LLVMBuildLoad2(m.builder, m.types.int16, address, "")
		unit := mark(m, load, m.places[.String])
		if instruction.type == ir.I32 {
			body.values[value] = llvm.LLVMBuildZExt(m.builder, unit, m.types.int32, "")
		} else {
			body.values[value] = llvm.LLVMBuildUIToFP(m.builder, unit, m.types.double, "")
		}

	case ir.Ascii_Cell:
		// The unit is below ir.ASCII_LIMIT, so its conversion is never poison.
		row := index_word(m, body, v.unit)
		body.values[value] = llvm.LLVMBuildInBoundsGEP2(
			m.builder,
			string_cell_type(m, 1),
			m.ascii_cells,
			&row,
			1,
			"",
		)

	case ir.Layout_Test:
		body.values[value] = build_layout_test(m, body.values[v.cell], v.layout)

	case ir.Null_Test:
		reference, null := body.values[v.value], llvm.LLVMConstNull(m.types.ptr)
		body.values[value] = llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, reference, null, "")

	case ir.Non_Null:
		body.values[value] = body.values[v.value]

	case ir.As_Layout:
		body.values[value] = body.values[v.cell]

	case ir.Same_Cell:
		a, b := body.values[v.a], body.values[v.b]
		body.values[value] = llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, a, b, "")

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
		load := llvm.LLVMBuildLoad2(m.builder, storage_type(m, type), m.globals[v.global], "")
		stored := mark(m, load, global_tag(m, type))
		body.values[value] = from_storage(m, stored, type)

	case ir.Global_Store:
		type := m.program.globals[v.global].type
		stored := to_storage(m, body.values[v.value], type)
		mark(m, llvm.LLVMBuildStore(m.builder, stored, m.globals[v.global]), global_tag(m, type))

	case ir.Env:
		body.values[value] = llvm.LLVMGetParam(body.function, 0)

	case ir.Func_Ref:
		body.values[value] = static_closure(m, v.func)

	case ir.Make_Closure:
		// The cell comes zero filled, so a function with no environment leaves that word null.
		closure := abi.Type_Table_ID(abi.Builtin_Table.Closure)
		cell: llvm.LLVMValueRef
		if v.place == .Stack {
			cell = start_stack_cell(m, body, value, closure)
		} else {
			cell = build_alloc(m, body, closure, size_of(abi.Closure_Cell))
		}
		code := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, code)))
		closure_store(m, m.funcs[v.func].function, code)
		if v.env != ir.NO_VALUE {
			env := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, env)))
			closure_store(m, body.values[v.env], env)
		}
		info := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, info)))
		closure_store(m, function_info(m, v.func), info)
		body.values[value] = cell

	case ir.Call:
		callee := m.funcs[v.func]
		env := llvm.LLVMConstNull(m.types.ptr)
		if v.env != ir.NO_VALUE {
			env = body.values[v.env]
		}
		result := call_function(m, body, callee.signature, callee.function, env, v.args)
		if instruction.type != ir.VOID {
			body.values[value] = from_storage(m, result, instruction.type)
		}

	case ir.Call_Closure:
		cell := body.values[v.callee]
		code_address := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, code)))
		code := closure_load(m, code_address)
		env_address := byte_offset(m, cell, int(offset_of(abi.Closure_Cell, env)))
		env := closure_load(m, env_address)
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
		args := make([dynamic]llvm.LLVMValueRef, context.temp_allocator)
		for param, i in export.params {
			if param == .Rest {
				address, count := pass_rest(m, body, v.args[i:])
				append(&args, address, count)
				break
			}
			// The verifier holds each argument to the C type of its parameter (ir.c_type_fits).
			append_argument(m, &args, body.values[v.args[i]], body.func.values[v.args[i]].type)
		}
		result := call_runtime(m, v.export, args[:])
		if instruction.type != ir.VOID {
			if export.result == .Boolean {
				result = llvm.LLVMBuildTrunc(m.builder, result, m.types.int1, "")
			}
			body.values[value] = result
		}

	case ir.Intrinsic:
		args := make([]llvm.LLVMValueRef, len(v.args), context.temp_allocator)
		for arg, i in v.args {
			args[i] = body.values[arg]
		}
		if v.op == .Min || v.op == .Max {
			body.values[value] = build_min_max(m, body, v.op, args)
		} else {
			body.values[value] = build_number_call(m, v.op, args)
		}

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
	call := llvm.LLVMBuildCall2(
		m.builder,
		callee.signature,
		callee.function,
		raw_data(args),
		u32(len(args)),
		"",
	)
	exports := abi.RUNTIME_EXPORTS
	return mark(m, call, m.places[.Collector] if exports[export].effect == .Allocates else nil)
}

// start_stack_cell fills the slot as tsnc_alloc fills a heap cell. The collector scans the slot
// with the rest of the stack, so the zeros also clear what an earlier pass left there.
@(private)
start_stack_cell :: proc(
	m: ^Module,
	body: ^Body,
	value: ir.Value_ID,
	table: abi.Type_Table_ID,
) -> llvm.LLVMValueRef {
	cell := body.cells[value]
	start_cell(m, cell.slot, cell.size, STACK_CELL_ALIGNMENT, table)
	return cell.slot
}

@(private)
start_cell :: proc(
	m: ^Module,
	cell: llvm.LLVMValueRef,
	extent: int,
	align: u32,
	table: abi.Type_Table_ID,
) {
	zero := llvm.LLVMConstInt(m.types.int8, 0, false)
	length := llvm.LLVMConstInt(m.types.int64, u64(extent), false)
	llvm.LLVMBuildMemSet(m.builder, cell, zero, length, align)
	table_word := llvm.LLVMConstInt(m.types.int32, u64(table), false)
	mark(m, llvm.LLVMBuildStore(m.builder, table_word, cell), m.places[.Header])
}

// build_alloc takes a small cell off its free list the way abi.Heap_Head describes, and calls
// tsnc_alloc where that gives none. Like a bounds check it splits the block and leaves the builder
// in the last part.
@(private)
build_alloc :: proc(
	m: ^Module,
	body: ^Body,
	table: abi.Type_Table_ID,
	size: int,
) -> llvm.LLVMValueRef {
	args := [?]llvm.LLVMValueRef{llvm.LLVMConstInt(m.types.int64, u64(table), false)}
	if size > abi.MAX_SMALL {
		return call_runtime(m, .Alloc, args[:])
	}
	class := abi.class_of(size)
	slot_size := llvm.LLVMConstInt(m.types.int64, u64(abi.CLASS_SIZE[class]), false)
	head := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, m.heap, "")
	free := byte_offset(m, head, int(offset_of(abi.Heap_Head, free)) + class * size_of(rawptr))
	slot := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, free, "")
	used_address := byte_offset(m, head, int(offset_of(abi.Heap_Head, used)))
	used := llvm.LLVMBuildLoad2(m.builder, m.types.int64, used_address, "")
	limit_address := byte_offset(m, head, int(offset_of(abi.Heap_Head, limit)))
	limit := llvm.LLVMBuildLoad2(m.builder, m.types.int64, limit_address, "")
	grown := llvm.LLVMBuildNSWAdd(m.builder, used, slot_size, "")
	null := llvm.LLVMConstNull(m.types.ptr)
	has_slot := llvm.LLVMBuildICmp(m.builder, .LLVMIntNE, slot, null, "")
	within := llvm.LLVMBuildICmp(m.builder, .LLVMIntSLE, grown, limit, "")
	fast := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	slow := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	join := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	llvm.LLVMBuildCondBr(m.builder, llvm.LLVMBuildAnd(m.builder, has_slot, within, ""), fast, slow)

	llvm.LLVMPositionBuilderAtEnd(m.builder, fast)
	next_address := byte_offset(m, slot, int(offset_of(abi.Free_Slot, next)))
	next := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, next_address, "")
	llvm.LLVMBuildStore(m.builder, next, free)
	llvm.LLVMBuildStore(m.builder, grown, used_address)
	cells_address := byte_offset(m, head, int(offset_of(abi.Heap_Head, cells)))
	cells := llvm.LLVMBuildLoad2(m.builder, m.types.int64, cells_address, "")
	one := llvm.LLVMConstInt(m.types.int64, 1, false)
	llvm.LLVMBuildStore(m.builder, llvm.LLVMBuildNSWAdd(m.builder, cells, one, ""), cells_address)
	start_cell(m, slot, max(size, size_of(abi.Free_Slot)), align_of(abi.Free_Slot), table)
	llvm.LLVMBuildBr(m.builder, join)

	llvm.LLVMPositionBuilderAtEnd(m.builder, slow)
	cell := call_runtime(m, .Alloc, args[:])
	llvm.LLVMBuildBr(m.builder, join)

	llvm.LLVMPositionBuilderAtEnd(m.builder, join)
	answer := llvm.LLVMBuildPhi(m.builder, m.types.ptr, "")
	values := [?]llvm.LLVMValueRef{slot, cell}
	blocks := [?]llvm.LLVMBasicBlockRef{fast, slow}
	llvm.LLVMAddIncoming(answer, &values[0], &blocks[0], len(values))
	return answer
}


@(private)
build_stack_array :: proc(
	m: ^Module,
	body: ^Body,
	value: ir.Value_ID,
	v: ir.New_Array,
) -> llvm.LLVMValueRef {
	cell := start_stack_cell(m, body, value, ir.table_id(v.layout))
	// The verifier holds the length of an array on the stack to a constant.
	elements := int(body.func.values[v.length].variant.(ir.Const_Number).value)
	count := llvm.LLVMConstInt(m.types.int64, u64(elements), false)
	length := byte_offset(m, cell, int(offset_of(abi.Array_Cell, length)))
	capacity := byte_offset(m, cell, int(offset_of(abi.Array_Cell, capacity)))
	mark(m, llvm.LLVMBuildStore(m.builder, count, length), m.places[.Array_Length])
	mark(m, llvm.LLVMBuildStore(m.builder, count, capacity), m.places[.Array_Capacity])
	if elements > 0 {
		// Array_Cell.elements stays nil while the capacity is 0.
		slots := byte_offset(m, cell, size_of(abi.Array_Cell))
		address := byte_offset(m, cell, int(offset_of(abi.Array_Cell, elements)))
		mark(m, llvm.LLVMBuildStore(m.builder, slots, address), m.places[.Array_Elements])
	}
	return cell
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

// element_address takes an index a bounds check answered or opt proved, so its conversion is never
// poison.
@(private)
element_address :: proc(m: ^Module, body: ^Body, array, index: ir.Value_ID) -> llvm.LLVMValueRef {
	pointer := byte_offset(m, body.values[array], int(offset_of(abi.Array_Cell, elements)))
	load := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, pointer, "")
	elements := mark(m, load, m.places[.Array_Elements])
	position := index_word(m, body, index)
	element := element_type(m, body, array)
	return llvm.LLVMBuildInBoundsGEP2(m.builder, element, elements, &position, 1, "")
}

// element_type is slot_type but for a boolean, which an array holds in one byte (abi.ELEMENT_SIZE).
@(private)
element_type :: proc(m: ^Module, body: ^Body, array: ir.Value_ID) -> llvm.LLVMTypeRef {
	kind := m.program.layouts[body.func.values[array].type.layout].element
	return m.types.int8 if kind == .Boolean else slot_type(m, kind)
}

// index_word takes a number the caller proved an integer, so fptosi is never poison.
@(private)
index_word :: proc(m: ^Module, body: ^Body, index: ir.Value_ID) -> llvm.LLVMValueRef {
	#partial switch body.func.values[index].type.kind {
	case .I32:
		return llvm.LLVMBuildSExt(m.builder, body.values[index], m.types.int64, "")
	case .I64:
		return body.values[index]
	}
	return llvm.LLVMBuildFPToSI(m.builder, body.values[index], m.types.int64, "")
}

@(private)
store :: proc(m: ^Module, body: ^Body, value: ir.Value_ID, address, tag: llvm.LLVMValueRef) {
	stored := to_storage(m, body.values[value], body.func.values[value].type)
	mark(m, llvm.LLVMBuildStore(m.builder, stored, address), tag)
}

@(private)
closure_load :: proc(m: ^Module, address: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	load := llvm.LLVMBuildLoad2(m.builder, m.types.ptr, address, "")
	return mark(m, load, m.places[.Closure])
}

@(private)
closure_store :: proc(m: ^Module, value, address: llvm.LLVMValueRef) {
	mark(m, llvm.LLVMBuildStore(m.builder, value, address), m.places[.Closure])
}

@(private)
build_length :: proc(
	m: ^Module,
	cell: llvm.LLVMValueRef,
	place: Place,
	type: ir.Type,
) -> llvm.LLVMValueRef {
	#assert(offset_of(abi.Array_Cell, length) == offset_of(abi.String_Cell, length))
	pointer := byte_offset(m, cell, int(offset_of(abi.String_Cell, length)))
	load := llvm.LLVMBuildLoad2(m.builder, m.types.int64, pointer, "")
	length := mark(m, load, m.places[place])
	if type == ir.I64 {
		return length
	}
	return llvm.LLVMBuildSIToFP(m.builder, length, m.types.double, "")
}

// build_reserve calls the runtime only for a full array. Like a bounds check it splits the block
// and leaves the builder in the last part.
@(private)
build_reserve :: proc(m: ^Module, body: ^Body, array: llvm.LLVMValueRef) {
	length_address := byte_offset(m, array, int(offset_of(abi.Array_Cell, length)))
	length := llvm.LLVMBuildLoad2(m.builder, m.types.int64, length_address, "")
	mark(m, length, m.places[.Array_Length])
	capacity_address := byte_offset(m, array, int(offset_of(abi.Array_Cell, capacity)))
	capacity := llvm.LLVMBuildLoad2(m.builder, m.types.int64, capacity_address, "")
	mark(m, capacity, m.places[.Array_Capacity])
	full := llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, length, capacity, "")
	grow := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	join := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	llvm.LLVMBuildCondBr(m.builder, full, grow, join)

	llvm.LLVMPositionBuilderAtEnd(m.builder, grow)
	args := [?]llvm.LLVMValueRef{array}
	call_runtime(m, .Array_Reserve, args[:])
	llvm.LLVMBuildBr(m.builder, join)

	llvm.LLVMPositionBuilderAtEnd(m.builder, join)
}

// build_bounds_check splits the block: each failure gets a block of its own, and the code after
// the check goes on in a third, where the builder is left. An index that equals its truncation is an
// integer, which NaN is not; an infinity passes that test and fails the range. An integer index
// needs only the range, one unsigned comparison, since a negative one reads as a huge unsigned.
@(private)
build_bounds_check :: proc(m: ^Module, body: ^Body, v: ir.Bounds_Check) -> llvm.LLVMValueRef {
	index := body.values[v.index]
	place := length_place(body.func.values[v.array].type)
	in_range: llvm.LLVMValueRef
	if ir.is_integer(body.func.values[v.index].type) {
		length := build_length(m, body.values[v.array], place, ir.I64)
		position := index_word(m, body, v.index)
		in_range = llvm.LLVMBuildICmp(m.builder, .LLVMIntULT, position, length, "")
	} else {
		length := build_length(m, body.values[v.array], place, ir.F64)
		argument := [?]llvm.LLVMValueRef{index}
		whole := build_number_call(m, .Trunc, argument[:])
		is_integer := llvm.LLVMBuildFCmp(m.builder, .LLVMRealOEQ, index, whole, "")
		integer := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
		not_integer := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
		llvm.LLVMBuildCondBr(m.builder, is_integer, integer, not_integer)

		llvm.LLVMPositionBuilderAtEnd(m.builder, not_integer)
		build_fail(m, v.not_integer)

		llvm.LLVMPositionBuilderAtEnd(m.builder, integer)
		zero := llvm.LLVMConstReal(m.types.double, 0)
		from_start := llvm.LLVMBuildFCmp(m.builder, .LLVMRealOGE, index, zero, "")
		before_end := llvm.LLVMBuildFCmp(m.builder, .LLVMRealOLT, index, length, "")
		in_range = llvm.LLVMBuildAnd(m.builder, from_start, before_end, "")
	}
	inside := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
	outside := llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, "")
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
	header := mark(m, llvm.LLVMBuildLoad2(m.builder, m.types.int32, cell, ""), m.places[.Header])
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
	case .Ref, .Ref_Or_Null, .Ref_Or_Undefined, .Any_Ref, .Any_Ref_Or_Null, .Any_Ref_Or_Undefined:
		return m.types.ptr
	case .Tagged:
		return m.types.tagged
	}
	unreachable()
}

@(private)
build_unary :: proc(m: ^Module, body: ^Body, v: ir.Unary, type: ir.Type) -> llvm.LLVMValueRef {
	operand := body.values[v.operand]
	switch v.op {
	case .Negate:
		if ir.is_integer(type) {
			// opt narrows a negation only of a range that holds no 0, whose negation would be -0.
			return llvm.LLVMBuildNSWNeg(m.builder, operand, "")
		}
		return llvm.LLVMBuildFNeg(m.builder, operand, "")
	case .Not:
		return llvm.LLVMBuildNot(m.builder, operand, "")
	case .Bit_Not:
		inverted := llvm.LLVMBuildNot(m.builder, to_int32(m, body, v.operand), "")
		return from_int32(m, inverted, type)
	}
	unreachable()
}

@(private)
build_compare :: proc(m: ^Module, body: ^Body, v: ir.Compare) -> llvm.LLVMValueRef {
	left, right := body.values[v.left], body.values[v.right]
	type := body.func.values[v.left].type
	if type == ir.F64 {
		return llvm.LLVMBuildFCmp(m.builder, REAL_PREDICATES[v.op], left, right, "")
	}
	if ir.is_integer(type) {
		return llvm.LLVMBuildICmp(m.builder, INTEGER_PREDICATES[v.op], left, right, "")
	}
	// The verifier keeps the ordered comparisons on numbers, so what reaches here is the equality
	// of two booleans, or of two references, which compare by address.
	predicate := llvm.LLVMIntPredicate.LLVMIntEQ if v.op == .Equal else .LLVMIntNE
	return llvm.LLVMBuildICmp(m.builder, predicate, left, right, "")
}

// INTEGER_PREDICATES are signed: a narrowed integer is a number that may be negative.
@(private, rodata)
INTEGER_PREDICATES := [ir.Compare_Op]llvm.LLVMIntPredicate {
	.Less          = .LLVMIntSLT,
	.Less_Equal    = .LLVMIntSLE,
	.Greater       = .LLVMIntSGT,
	.Greater_Equal = .LLVMIntSGE,
	.Equal         = .LLVMIntEQ,
	.Not_Equal     = .LLVMIntNE,
}

// build_convert is exact both ways: opt converts an F64 to an integer only where it proved the
// value one that fits, so fptosi is never poison.
@(private)
build_convert :: proc(m: ^Module, body: ^Body, v: ir.Convert, type: ir.Type) -> llvm.LLVMValueRef {
	value := body.values[v.value]
	from := body.func.values[v.value].type
	switch {
	case from == ir.F64:
		return llvm.LLVMBuildFPToSI(m.builder, value, value_type(m, type), "")
	case type == ir.F64:
		return llvm.LLVMBuildSIToFP(m.builder, value, m.types.double, "")
	}
	return llvm.LLVMBuildSExt(m.builder, value, m.types.int64, "")
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
	case .Ref, .Any_Ref:
		// Objects and arrays share the tag; the type table of the cell tells them apart.
		tag = .Object
		payload = llvm.LLVMBuildPtrToInt(m.builder, value, m.types.int64, "")
	case .Closure:
		tag = .Function
		payload = llvm.LLVMBuildPtrToInt(m.builder, value, m.types.int64, "")
	case .Void, .Tagged, .I32, .I64:
		// The verifier keeps each of them out of box.
		unreachable()
	}
	tag_word := llvm.LLVMConstInt(m.types.int64, u64(tag), false)
	nullish: abi.Tag
	switch type.nullish {
	case .None:
		return tagged_words(m, tag_word, payload)
	case .Null:
		nullish = .Null
	case .Undefined:
		nullish = .Undefined
	}
	// The payload of the null reference is 0, which is what null and undefined carry.
	null := llvm.LLVMBuildICmp(m.builder, .LLVMIntEQ, value, llvm.LLVMConstNull(m.types.ptr), "")
	nullish_word := llvm.LLVMConstInt(m.types.int64, u64(nullish), false)
	tag_or_nullish := llvm.LLVMBuildSelect(m.builder, null, nullish_word, tag_word, "")
	return tagged_words(m, tag_or_nullish, payload)
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
	case .Str, .Ref, .Any_Ref, .Closure:
		return llvm.LLVMBuildIntToPtr(m.builder, payload, m.types.ptr, "")
	case .Void, .Tagged, .I32, .I64:
		// The verifier keeps each of them out of unbox.
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
