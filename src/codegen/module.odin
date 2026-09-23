package codegen

import "core:log"
import "core:strings"

import "../abi"
import "../ir"
import "../llvm"

// The LLVM type of a String_Cell is { i32, i32, i64, [N x i16] }: the two header words, the length,
// then N UTF-16 units. These pin the Odin layout the mapping relies on.
#assert(size_of(abi.Type_Table_ID) == 4)
#assert(size_of(abi.Cell_Flags) == 4)
#assert(offset_of(abi.String_Cell, length) == 8)
#assert(size_of(int) == 8)

// A Fail_Site is { ptr, i64, i32, i32, i32 }: the path as an Odin string, then the line, the column
// and the error code. LLVM pads the tail to the 8 byte alignment, which is where the 32 bytes come
// from.
#assert(size_of(abi.Fail_Site) == 32)
#assert(size_of(string) == 16)
#assert(offset_of(abi.Fail_Site, line) == 16)
#assert(offset_of(abi.Fail_Site, column) == 20)
#assert(offset_of(abi.Fail_Site, error) == 24)
#assert(size_of(abi.Runtime_Error) == 4)

// A Tagged is { i64, i64 }: the tag and the payload word, which holds a double, a b64 or a pointer.
#assert(size_of(abi.Tagged) == 16)
#assert(size_of(abi.Tag) == 8)
#assert(offset_of(abi.Tagged, payload) == 8)

// Function keeps the signature next to the function because LLVMBuildCall2 needs it.
@(private)
Function :: struct {
	signature: llvm.LLVMTypeRef,
	function:  llvm.LLVMValueRef,
}

@(private)
Types :: struct {
	void:   llvm.LLVMTypeRef,
	double: llvm.LLVMTypeRef,
	int1:   llvm.LLVMTypeRef,
	int8:   llvm.LLVMTypeRef,
	int16:  llvm.LLVMTypeRef,
	int32:  llvm.LLVMTypeRef,
	int64:  llvm.LLVMTypeRef,
	ptr:    llvm.LLVMTypeRef,
	tagged: llvm.LLVMTypeRef,
}

// Module lives in the temp allocator of the emit call that builds it.
@(private)
Module :: struct {
	ctx:          llvm.LLVMContextRef,
	module:       llvm.LLVMModuleRef,
	builder:      llvm.LLVMBuilderRef,
	program:      ^ir.Program_IR,
	types:        Types,
	runtime:      [abi.Runtime_Proc]Function,
	funcs:        []Function, // by ir.Func_ID
	globals:      []llvm.LLVMValueRef, // by ir.Global_ID
	// string_cells is Program_IR.strings under another name: a field named strings would shadow the
	// core:strings import inside the struct declaration.
	string_cells: []llvm.LLVMValueRef, // by ir.String_ID
	fail_sites:   []llvm.LLVMValueRef, // by ir.Fail_Site_ID
	libm:         map[string]Function, // by C symbol, so each libm function is declared once
	unsupported:  string, // the mnemonic of the first instruction codegen cannot emit yet
}

@(private)
build_module :: proc(
	ctx: llvm.LLVMContextRef,
	module: llvm.LLVMModuleRef,
	program: ^ir.Program_IR,
	unit: ir.Unit,
) -> Error {
	m := Module {
		ctx     = ctx,
		module  = module,
		program = program,
		types   = make_types(ctx),
		builder = llvm.LLVMCreateBuilderInContext(ctx),
		libm    = make(map[string]Function, context.temp_allocator),
	}
	defer llvm.LLVMDisposeBuilder(m.builder)
	m.runtime = declare_runtime(ctx, module, m.types)

	add_string_cells(&m)
	add_fail_sites(&m)
	add_type_tables(&m)
	add_globals(&m)
	add_roots(&m)
	declare_funcs(&m, unit)

	for id in unit.funcs {
		build_func(&m, id)
		if m.unsupported != "" {
			log.errorf(
				"codegen: %s in %s: the runtime of this instruction arrives with milestone 5",
				m.unsupported,
				program.funcs[id].name,
			)
			return .Unsupported_Instruction
		}
	}
	return .None
}

@(private)
make_types :: proc(ctx: llvm.LLVMContextRef) -> (types: Types) {
	types = Types {
		void   = llvm.LLVMVoidTypeInContext(ctx),
		double = llvm.LLVMDoubleTypeInContext(ctx),
		int1   = llvm.LLVMInt1TypeInContext(ctx),
		int8   = llvm.LLVMInt8TypeInContext(ctx),
		int16  = llvm.LLVMInt16TypeInContext(ctx),
		int32  = llvm.LLVMInt32TypeInContext(ctx),
		int64  = llvm.LLVMInt64TypeInContext(ctx),
		ptr    = llvm.LLVMPointerTypeInContext(ctx, 0),
	}
	// A named struct, so the text of a tagged value reads as one thing in -emit-llvm output.
	TAGGED :: "tsnc.tagged"
	types.tagged = llvm.LLVMStructCreateNamed(ctx, TAGGED)
	words := [2]llvm.LLVMTypeRef{types.int64, types.int64}
	llvm.LLVMStructSetBody(types.tagged, &words[0], len(words), false)
	return
}

// value_type is how a value of the IR type sits in a register.
@(private)
value_type :: proc(m: ^Module, type: ir.Type) -> llvm.LLVMTypeRef {
	switch type.kind {
	case .Void:
		return m.types.void
	case .F64:
		return m.types.double
	case .Bool:
		return m.types.int1
	case .Tagged:
		return m.types.tagged
	case .Str, .Closure, .Ref:
		// Opaque pointers: a reference is the address of a cell, and its layout is compile time
		// knowledge that never reaches the LLVM type.
		return m.types.ptr
	}
	unreachable()
}

// storage_type is how a value of the IR type sits in memory. Only a boolean differs: abi stores it
// as b64, in a slot, in a tagged payload and in a runtime argument alike, so one rule holds
// everywhere - i1 in a register, i64 in memory.
@(private)
storage_type :: proc(m: ^Module, type: ir.Type) -> llvm.LLVMTypeRef {
	if type.kind == .Bool {
		return m.types.int64
	}
	return value_type(m, type)
}

// declare_runtime marks a diverging export noreturn, so LLVM treats the code after its call as
// unreachable.
@(private)
declare_runtime :: proc(
	ctx: llvm.LLVMContextRef,
	module: llvm.LLVMModuleRef,
	types: Types,
) -> (
	functions: [abi.Runtime_Proc]Function,
) {
	NORETURN :: "noreturn"
	noreturn := llvm.LLVMCreateEnumAttribute(
		ctx,
		llvm.LLVMGetEnumAttributeKindForName(NORETURN, len(NORETURN)),
		0,
	)
	exports := abi.RUNTIME_EXPORTS
	for export, id in exports {
		params := make([dynamic]llvm.LLVMTypeRef, context.temp_allocator)
		result := export.result
		if result == .Tagged {
			// The caller's slot for it comes first, and the export returns nothing.
			append(&params, types.ptr)
			result = .Void
		}
		for param in export.params {
			if param == .Tagged {
				append(&params, types.int64, types.int64)
			} else {
				append(&params, c_type(types, param))
			}
		}
		signature := llvm.LLVMFunctionType(
			c_type(types, result),
			raw_data(params),
			u32(len(params)),
			false,
		)
		symbol := strings.clone_to_cstring(export.symbol, context.temp_allocator)
		function := llvm.LLVMAddFunction(module, symbol, signature)
		if export.diverges {
			llvm.LLVMAddAttributeAtIndex(function, llvm.LLVMAttributeFunctionIndex, noreturn)
		}
		functions[id] = {signature, function}
	}
	return
}

@(private)
c_type :: proc(types: Types, kind: abi.C_Type) -> llvm.LLVMTypeRef {
	switch kind {
	case .Void:
		return types.void
	case .Ptr:
		return types.ptr
	case .Number:
		return types.double
	case .Boolean:
		// b64, so the call site widens its i1 and no export depends on how a C ABI passes a
		// narrower boolean.
		return types.int64
	case .Tagged:
		// Two parameters, or a slot for a result, which declare_runtime spells itself.
		unreachable()
	}
	unreachable()
}

// declare_funcs lets only tsnc_main leave the object file, because the runtime calls it; the rest
// of the unit is internal, which in v1 - one unit holding the whole program - lets the optimizer
// see all of it. A function outside the unit stays an external declaration, which is what v2 needs
// when a call crosses units.
@(private)
declare_funcs :: proc(m: ^Module, unit: ir.Unit) {
	m.funcs = make([]Function, len(m.program.funcs), context.temp_allocator)
	in_unit := make([]bool, len(m.program.funcs), context.temp_allocator)
	for id in unit.funcs {
		in_unit[id] = true
	}
	for body, i in m.program.funcs {
		id := ir.Func_ID(i)
		signature := func_signature(m, body)
		name := strings.clone_to_cstring(body.name, context.temp_allocator)
		function := llvm.LLVMAddFunction(m.module, name, signature)
		if in_unit[id] && id != m.program.main {
			llvm.LLVMSetLinkage(function, .LLVMInternalLinkage)
		}
		m.funcs[id] = {signature, function}
	}
}

// func_signature puts the environment of a function that captures ahead of the TypeScript
// parameters, which is the closure convention of abi.
@(private)
func_signature :: proc(m: ^Module, body: ir.Func) -> llvm.LLVMTypeRef {
	first := 1 if body.env != ir.NO_LAYOUT else 0
	params := make([]llvm.LLVMTypeRef, first + len(body.params), context.temp_allocator)
	if first == 1 {
		params[0] = m.types.ptr
	}
	for type, i in body.params {
		params[first + i] = value_type(m, type)
	}
	return llvm.LLVMFunctionType(
		value_type(m, body.result),
		raw_data(params),
		u32(len(params)),
		false,
	)
}

// add_globals gives every module binding a zero filled cell in the data segment. The zero is load
// bearing: abi.Tag.Undefined is zero, so a tagged binding reads as undefined before its module init
// has run, and a reference reads as null.
@(private)
add_globals :: proc(m: ^Module) {
	m.globals = make([]llvm.LLVMValueRef, len(m.program.globals), context.temp_allocator)
	for binding, i in m.program.globals {
		type := storage_type(m, binding.type)
		name := strings.clone_to_cstring(binding.name, context.temp_allocator)
		global := llvm.LLVMAddGlobal(m.module, type, name)
		llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(type))
		llvm.LLVMSetLinkage(global, .LLVMInternalLinkage)
		m.globals[i] = global
	}
}

// A row is { ptr, i8 }, which LLVM pads to the 16 bytes of abi.Root. Since a root's address leaves
// the module, LLVM can no longer fold the global away or keep it in a register, and the collector
// reads what the program stored.
@(private)
add_roots :: proc(m: ^Module) {
	row_types := [?]llvm.LLVMTypeRef{m.types.ptr, m.types.int8}
	row_type := llvm.LLVMStructTypeInContext(m.ctx, &row_types[0], len(row_types), false)
	rows := make([dynamic]llvm.LLVMValueRef, 0, len(m.program.globals), context.temp_allocator)
	for binding, i in m.program.globals {
		kind, is_root := root_kind(binding.type)
		if !is_root {
			continue
		}
		values := [?]llvm.LLVMValueRef {
			m.globals[i],
			llvm.LLVMConstInt(m.types.int8, u64(kind), false),
		}
		append(&rows, llvm.LLVMConstStructInContext(m.ctx, &values[0], len(values), false))
	}
	roots := add_constant_array(m, row_type, rows[:], "roots")
	add_slice_procedure(m, abi.ROOTS_SYMBOL, roots, len(rows), "roots.slice")
}

@(private)
root_kind :: proc(type: ir.Type) -> (kind: abi.Slot_Kind, is_root: bool) {
	switch type.kind {
	case .Void, .F64, .Bool:
		return {}, false
	case .Tagged:
		return .Tagged, true
	case .Str, .Closure, .Ref:
		return .Ref, true
	}
	unreachable()
}

// add_string_cells emits the units as the pool holds them: it keeps a lone surrogate that no UTF-8
// round trip would survive.
@(private)
add_string_cells :: proc(m: ^Module) {
	m.string_cells = make([]llvm.LLVMValueRef, len(m.program.strings), context.temp_allocator)
	for units, i in m.program.strings {
		m.string_cells[i] = add_string_cell(m, units)
	}
}

// add_string_cell makes the cell constant: it lives in read-only data, and the GC never marks it
// (see abi).
@(private)
add_string_cell :: proc(m: ^Module, units: []u16) -> llvm.LLVMValueRef {
	unit_values := make([]llvm.LLVMValueRef, len(units), context.temp_allocator)
	for unit, i in units {
		unit_values[i] = llvm.LLVMConstInt(m.types.int16, u64(unit), false)
	}

	field_types := [?]llvm.LLVMTypeRef {
		m.types.int32,
		m.types.int32,
		m.types.int64,
		llvm.LLVMArrayType2(m.types.int16, u64(len(units))),
	}
	fields := [?]llvm.LLVMValueRef {
		llvm.LLVMConstInt(m.types.int32, u64(abi.Builtin_Table.String), false), // header.type_table
		llvm.LLVMConstInt(m.types.int32, 0, false), // header.flags: none
		llvm.LLVMConstInt(m.types.int64, u64(len(units)), false), // length
		llvm.LLVMConstArray2(m.types.int16, raw_data(unit_values), u64(len(unit_values))), // units
	}
	cell_type := llvm.LLVMStructTypeInContext(m.ctx, &field_types[0], len(field_types), false)
	cell := llvm.LLVMAddGlobal(m.module, cell_type, "str")
	llvm.LLVMSetInitializer(
		cell,
		llvm.LLVMConstStructInContext(m.ctx, &fields[0], len(fields), false),
	)
	llvm.LLVMSetGlobalConstant(cell, true)
	llvm.LLVMSetLinkage(cell, .LLVMPrivateLinkage)
	llvm.LLVMSetUnnamedAddress(cell, .LLVMGlobalUnnamedAddr)
	llvm.LLVMSetAlignment(cell, align_of(abi.String_Cell))
	return cell
}

// add_fail_sites writes the constants tsnc_fail reads to print where the program failed. The paths
// are shared: a program has many more sites than files.
@(private)
add_fail_sites :: proc(m: ^Module) {
	m.fail_sites = make([]llvm.LLVMValueRef, len(m.program.fail_sites), context.temp_allocator)
	paths := make(map[string]llvm.LLVMValueRef, context.temp_allocator)

	field_types := [?]llvm.LLVMTypeRef {
		m.types.ptr,
		m.types.int64,
		m.types.int32,
		m.types.int32,
		m.types.int32,
	}
	site_type := llvm.LLVMStructTypeInContext(m.ctx, &field_types[0], len(field_types), false)

	for site, i in m.program.fail_sites {
		path, known := paths[site.file]
		if !known {
			path = add_text(m, site.file)
			paths[site.file] = path
		}
		fields := [?]llvm.LLVMValueRef {
			path,
			llvm.LLVMConstInt(m.types.int64, u64(len(site.file)), false),
			llvm.LLVMConstInt(m.types.int32, u64(site.line), true),
			llvm.LLVMConstInt(m.types.int32, u64(site.column), true),
			llvm.LLVMConstInt(m.types.int32, u64(site.error), false),
		}
		global := llvm.LLVMAddGlobal(m.module, site_type, "fail_site")
		llvm.LLVMSetInitializer(
			global,
			llvm.LLVMConstStructInContext(m.ctx, &fields[0], len(fields), false),
		)
		llvm.LLVMSetGlobalConstant(global, true)
		llvm.LLVMSetLinkage(global, .LLVMPrivateLinkage)
		llvm.LLVMSetUnnamedAddress(global, .LLVMGlobalUnnamedAddr)
		llvm.LLVMSetAlignment(global, align_of(abi.Fail_Site))
		m.fail_sites[i] = global
	}
}

// add_type_tables writes the layouts as the type tables the collector and console read, in
// Type_Table_ID order after the builtin ones, and defines tsnc_type_tables, which hands the
// runtime's main a slice of them. A Field is { ptr, i64, i64, i8 } and a Type_Table is
// { i8, i64, ptr, i64, i8 }: a string and a slice are a pointer and a length, and LLVM pads the
// tails the way Odin does, which the #asserts at the end of abi.odin pin. The names are shared: an
// environment has none, and objects repeat theirs.
@(private)
add_type_tables :: proc(m: ^Module) {
	types := m.types
	field_types := [?]llvm.LLVMTypeRef{types.ptr, types.int64, types.int64, types.int8}
	field_type := llvm.LLVMStructTypeInContext(m.ctx, &field_types[0], len(field_types), false)
	table_types := [?]llvm.LLVMTypeRef{types.int8, types.int64, types.ptr, types.int64, types.int8}
	table_type := llvm.LLVMStructTypeInContext(m.ctx, &table_types[0], len(table_types), false)
	names := make(map[string]llvm.LLVMValueRef, context.temp_allocator)

	// Layout row 0 is reserved for NO_LAYOUT; the rows after it are the tables ir.table_id numbers.
	rows := m.program.layouts[1:]
	tables := make([]llvm.LLVMValueRef, len(rows), context.temp_allocator)
	for table, i in rows {
		fields := make([]llvm.LLVMValueRef, len(table.fields), context.temp_allocator)
		for field, j in table.fields {
			name := llvm.LLVMConstNull(types.ptr)
			if field.name != "" {
				known: bool
				name, known = names[field.name]
				if !known {
					name = add_text(m, field.name)
					names[field.name] = name
				}
			}
			values := [?]llvm.LLVMValueRef {
				name,
				llvm.LLVMConstInt(types.int64, u64(len(field.name)), false),
				llvm.LLVMConstInt(types.int64, u64(field.offset), false),
				llvm.LLVMConstInt(types.int8, u64(field.kind), false),
			}
			fields[j] = llvm.LLVMConstStructInContext(m.ctx, &values[0], len(values), false)
		}

		values := [?]llvm.LLVMValueRef {
			llvm.LLVMConstInt(types.int8, u64(table.kind), false),
			llvm.LLVMConstInt(types.int64, u64(table.size), false),
			add_constant_array(m, field_type, fields, "fields"),
			llvm.LLVMConstInt(types.int64, u64(len(fields)), false),
			llvm.LLVMConstInt(types.int8, u64(table.element), false),
		}
		tables[i] = llvm.LLVMConstStructInContext(m.ctx, &values[0], len(values), false)
	}

	type_tables := add_constant_array(m, table_type, tables, "type_tables")
	add_slice_procedure(m, abi.TYPE_TABLES_SYMBOL, type_tables, len(tables), "type_tables.slice")
}

@(private)
add_slice_procedure :: proc(
	m: ^Module,
	symbol: cstring,
	data: llvm.LLVMValueRef,
	count: int,
	name: cstring,
) {
	types := m.types
	slice := [?]llvm.LLVMValueRef{data, llvm.LLVMConstInt(types.int64, u64(count), false)}
	slice_types := [?]llvm.LLVMTypeRef{types.ptr, types.int64}
	slice_type := llvm.LLVMStructTypeInContext(m.ctx, &slice_types[0], len(slice_types), false)
	global := llvm.LLVMAddGlobal(m.module, slice_type, name)
	llvm.LLVMSetInitializer(
		global,
		llvm.LLVMConstStructInContext(m.ctx, &slice[0], len(slice), false),
	)
	llvm.LLVMSetGlobalConstant(global, true)
	llvm.LLVMSetLinkage(global, .LLVMPrivateLinkage)
	llvm.LLVMSetAlignment(global, align_of([]byte))

	signature := llvm.LLVMFunctionType(types.ptr, nil, 0, false)
	answer := llvm.LLVMAddFunction(m.module, symbol, signature)
	llvm.LLVMPositionBuilderAtEnd(m.builder, llvm.LLVMAppendBasicBlockInContext(m.ctx, answer, ""))
	llvm.LLVMBuildRet(m.builder, global)
}

// add_constant_array answers the address of a private constant holding the elements, or a null
// pointer when there are none, which is the data pointer of an empty Odin slice. The elements are
// abi structs, and every one of them is word aligned.
@(private)
add_constant_array :: proc(
	m: ^Module,
	element_type: llvm.LLVMTypeRef,
	elements: []llvm.LLVMValueRef,
	name: cstring,
) -> llvm.LLVMValueRef {
	if len(elements) == 0 {
		return llvm.LLVMConstNull(m.types.ptr)
	}
	count := u64(len(elements))
	global := llvm.LLVMAddGlobal(m.module, llvm.LLVMArrayType2(element_type, count), name)
	llvm.LLVMSetInitializer(global, llvm.LLVMConstArray2(element_type, raw_data(elements), count))
	llvm.LLVMSetGlobalConstant(global, true)
	llvm.LLVMSetLinkage(global, .LLVMPrivateLinkage)
	llvm.LLVMSetUnnamedAddress(global, .LLVMGlobalUnnamedAddr)
	llvm.LLVMSetAlignment(global, align_of(rawptr))
	return global
}

// add_text adds the bytes of an Odin string, without a terminator: the runtime reads the length
// from the value that points here.
@(private)
add_text :: proc(m: ^Module, text: string) -> llvm.LLVMValueRef {
	bytes := llvm.LLVMConstStringInContext(m.ctx, raw_data(text), u32(len(text)), true)
	global := llvm.LLVMAddGlobal(
		m.module,
		llvm.LLVMArrayType2(m.types.int8, u64(len(text))),
		"text",
	)
	llvm.LLVMSetInitializer(global, bytes)
	llvm.LLVMSetGlobalConstant(global, true)
	llvm.LLVMSetLinkage(global, .LLVMPrivateLinkage)
	llvm.LLVMSetUnnamedAddress(global, .LLVMGlobalUnnamedAddr)
	return global
}
