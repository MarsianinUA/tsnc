package ir

import "core:io"
import "core:strconv"

import "../abi"
import "../source"

/*
The text dump behind `tsnc build -emit-ir`, and the one line a violation of the verifier prints as.
It is a debugging artifact: it is read next to the TypeScript it came from, never parsed back.

Shape: one fact per line, indentation for what belongs to the line above. The layouts, the globals,
the string constants and the failure sites come first, then the functions, then the entry points.
An instruction that defines a value opens with `%<id> = ` and ends with ` : <type>`; every
instruction ends with the line and the column it came from, and a function names the file, because
lower builds one function out of one module.

Deterministic by construction: everything printed is an array index or array order, and nothing here
reads a map, whose iteration order changes between runs. Two runs of the same compiler over the same
program write the same bytes, which is what the determinism test of milestone 6 asks of -emit-ir.

The dump is ASCII. A string constant is UTF-16 and may hold a lone surrogate on purpose, so it
prints unit by unit with everything outside printable ASCII as an escape, and no unit is lost to a
replacement character on the way out.
*/

// write_program takes the file table, indexed by source.File_ID, to turn the span of an instruction
// into a line and a column.
write_program :: proc(w: io.Writer, files: []source.File, p: Program_IR) -> io.Error {
	io.write_string(w, "; tsnc ir\n") or_return

	// Layout row 0 is reserved for NO_LAYOUT and no program names it.
	for table, id in p.layouts {
		if Layout_ID(id) == NO_LAYOUT {
			continue
		}
		// A layout that never went through the builder has no base, and is a layout of its own.
		base := p.base[id] if id < len(p.base) else Layout_ID(id)
		write_layout(w, Layout_ID(id), table, base) or_return
	}
	for global, id in p.globals {
		io.write_string(w, "global ") or_return
		io.write_int(w, id) or_return
		io.write_byte(w, ' ') or_return
		io.write_string(w, global.name) or_return
		io.write_string(w, " : ") or_return
		write_type(w, global.type) or_return
		io.write_byte(w, '\n') or_return
	}
	for units, id in p.strings {
		io.write_string(w, "string ") or_return
		io.write_int(w, id) or_return
		io.write_byte(w, ' ') or_return
		write_units(w, units) or_return
		io.write_byte(w, '\n') or_return
	}
	for site, id in p.fail_sites {
		io.write_string(w, "fail ") or_return
		io.write_int(w, id) or_return
		io.write_byte(w, ' ') or_return
		io.write_string(w, RUNTIME_ERROR_TEXT[site.error]) or_return
		io.write_string(w, " at ") or_return
		io.write_string(w, site.file) or_return
		io.write_byte(w, ':') or_return
		io.write_int(w, int(site.line)) or_return
		io.write_byte(w, ':') or_return
		io.write_int(w, int(site.column)) or_return
		io.write_byte(w, '\n') or_return
	}

	for id in 0 ..< len(p.funcs) {
		write_func(w, files, p, Func_ID(id)) or_return
	}

	io.write_string(w, "init") or_return
	for id in p.init_order {
		io.write_byte(w, ' ') or_return
		io.write_int(w, int(id)) or_return
	}
	io.write_string(w, "\nmain ") or_return
	io.write_int(w, int(p.main)) or_return
	io.write_byte(w, '\n') or_return
	for unit, id in p.units {
		io.write_string(w, "unit ") or_return
		io.write_int(w, id) or_return
		io.write_string(w, " funcs") or_return
		for func in unit.funcs {
			io.write_byte(w, ' ') or_return
			io.write_int(w, int(func)) or_return
		}
		io.write_byte(w, '\n') or_return
	}
	return nil
}

write_func :: proc(w: io.Writer, files: []source.File, p: Program_IR, id: Func_ID) -> io.Error {
	func := p.funcs[id]
	io.write_string(w, "func ") or_return
	io.write_int(w, int(id)) or_return
	io.write_byte(w, ' ') or_return
	io.write_string(w, func.name) or_return
	io.write_byte(w, '(') or_return
	for type, i in func.params {
		if i > 0 {
			io.write_string(w, ", ") or_return
		}
		write_type(w, type) or_return
	}
	io.write_string(w, ") -> ") or_return
	write_type(w, func.result) or_return
	if func.env != NO_LAYOUT {
		io.write_string(w, " env ") or_return
		io.write_int(w, int(func.env)) or_return
	}
	if info, described := func.info.?; described {
		io.write_string(w, " closure ") or_return
		if int(info.name) < len(p.strings) {
			write_units(w, p.strings[info.name]) or_return
		} else {
			io.write_byte(w, '?') or_return
		}
		io.write_string(w, " length ") or_return
		io.write_int(w, int(info.length)) or_return
		if info.has_prototype {
			io.write_string(w, " prototype") or_return
		}
	}
	write_place(w, files, func.span) or_return
	io.write_byte(w, '\n') or_return

	for block, index in func.blocks {
		io.write_string(w, "  b") or_return
		io.write_int(w, index) or_return
		io.write_string(w, ":\n") or_return
		for value in block.instructions {
			if int(value) >= len(func.values) {
				continue // a program the verifier rejects still prints what it can
			}
			write_instruction(w, files, p, func, value) or_return
		}
	}
	return nil
}

// write_violation writes one line: whose instruction it is, what the verifier found, and where the
// instruction came from.
write_violation :: proc(
	w: io.Writer,
	files: []source.File,
	p: Program_IR,
	violation: Violation,
) -> io.Error {
	known := int(violation.func) < len(p.funcs)
	if known {
		io.write_string(w, p.funcs[violation.func].name) or_return
	} else {
		io.write_string(w, "func ") or_return
		io.write_int(w, int(violation.func)) or_return
	}
	if violation.block != NO_BLOCK {
		io.write_string(w, ":b") or_return
		io.write_int(w, int(violation.block)) or_return
	}
	if violation.value != NO_VALUE {
		io.write_string(w, ":%") or_return
		io.write_int(w, int(violation.value)) or_return
	}
	io.write_string(w, ": ") or_return
	io.write_string(w, VIOLATION_TEXT[violation.kind]) or_return
	if known && violation.value != NO_VALUE {
		func := p.funcs[violation.func]
		if int(violation.value) < len(func.values) {
			write_place(w, files, func.values[violation.value].span) or_return
		}
	}
	io.write_byte(w, '\n') or_return
	return nil
}

// write_layout ends a table row with `order of <base>`, the layout whose fields it lists in another
// order.
@(private)
write_layout :: proc(
	w: io.Writer,
	id: Layout_ID,
	table: abi.Type_Table,
	base: Layout_ID,
) -> io.Error {
	io.write_string(w, "layout ") or_return
	io.write_int(w, int(id)) or_return
	io.write_byte(w, ' ') or_return
	io.write_string(w, CELL_KIND_TEXT[table.kind]) or_return
	if table.kind == .Array {
		io.write_byte(w, ' ') or_return
		io.write_string(w, SLOT_KIND_TEXT[table.element]) or_return
	}
	io.write_string(w, " size ") or_return
	io.write_int(w, table.size) or_return
	if base != id {
		io.write_string(w, " order of ") or_return
		io.write_int(w, int(base)) or_return
	}
	io.write_byte(w, '\n') or_return
	for field, index in table.fields {
		io.write_string(w, "  field ") or_return
		io.write_int(w, index) or_return
		io.write_byte(w, ' ') or_return
		write_text(w, field.name) or_return
		if field.optional {
			io.write_byte(w, '?') or_return
		}
		io.write_byte(w, ' ') or_return
		io.write_string(w, SLOT_KIND_TEXT[field.kind]) or_return
		io.write_string(w, " at ") or_return
		io.write_int(w, field.offset) or_return
		io.write_byte(w, '\n') or_return
	}
	return nil
}

@(private)
write_instruction :: proc(
	w: io.Writer,
	files: []source.File,
	p: Program_IR,
	func: Func,
	id: Value_ID,
) -> io.Error {
	instruction := func.values[id]
	io.write_string(w, "    ") or_return
	if instruction.type != VOID {
		write_value(w, id) or_return
		io.write_string(w, " = ") or_return
	}
	write_variant(w, p, instruction.variant) or_return
	if instruction.type != VOID {
		io.write_string(w, " : ") or_return
		write_type(w, instruction.type) or_return
	}
	io.write_string(w, " ; ") or_return
	write_position(w, files, instruction.span) or_return
	io.write_byte(w, '\n') or_return
	return nil
}

// write_variant is the same exhaustive switch codegen is: a variant added to the union without a
// case here fails the build.
@(private)
write_variant :: proc(w: io.Writer, p: Program_IR, variant: Variant) -> io.Error {
	switch v in variant {
	case Unreachable:
		io.write_string(w, "unreachable") or_return

	case Param:
		io.write_string(w, "param ") or_return
		io.write_int(w, int(v.index)) or_return

	case Const_Number:
		io.write_string(w, "const ") or_return
		write_number(w, v.value) or_return

	case Const_Bool:
		io.write_string(w, "const ") or_return
		io.write_string(w, "true" if v.value else "false") or_return

	case Const_Undefined:
		io.write_string(w, "undefined") or_return

	case Const_Null:
		io.write_string(w, "null") or_return

	case Const_String:
		io.write_string(w, "string ") or_return
		io.write_int(w, int(v.text)) or_return

	case Binary:
		io.write_string(w, BINARY_TEXT[v.op]) or_return
		io.write_byte(w, ' ') or_return
		write_value(w, v.left) or_return
		io.write_string(w, ", ") or_return
		write_value(w, v.right) or_return

	case Unary:
		io.write_string(w, UNARY_TEXT[v.op]) or_return
		io.write_byte(w, ' ') or_return
		write_value(w, v.operand) or_return

	case Compare:
		io.write_string(w, COMPARE_TEXT[v.op]) or_return
		io.write_byte(w, ' ') or_return
		write_value(w, v.left) or_return
		io.write_string(w, ", ") or_return
		write_value(w, v.right) or_return

	case Phi:
		io.write_string(w, "phi") or_return
		for edge, i in v.incoming {
			io.write_string(w, " [b" if i == 0 else ", [b") or_return
			io.write_int(w, int(edge.block)) or_return
			io.write_byte(w, ' ') or_return
			write_value(w, edge.value) or_return
			io.write_byte(w, ']') or_return
		}

	case Alloc:
		io.write_string(w, "alloc ") or_return
		io.write_int(w, int(v.layout)) or_return
		if v.table != NO_LAYOUT {
			io.write_string(w, " table ") or_return
			io.write_int(w, int(v.table)) or_return
		}

	case New_Array:
		io.write_string(w, "new_array ") or_return
		io.write_int(w, int(v.layout)) or_return
		io.write_string(w, ", ") or_return
		write_value(w, v.length) or_return

	case Field_Load:
		io.write_string(w, "field_load ") or_return
		write_field(w, v.cell, v.field) or_return

	case Field_Store:
		io.write_string(w, "field_store ") or_return
		write_field(w, v.cell, v.field) or_return
		io.write_string(w, " = ") or_return
		write_value(w, v.value) or_return

	case Field_Store_Ref:
		io.write_string(w, "field_store_ref ") or_return
		write_field(w, v.cell, v.field) or_return
		io.write_string(w, " = ") or_return
		write_value(w, v.value) or_return

	case Length:
		io.write_string(w, "length ") or_return
		write_value(w, v.value) or_return

	case Bounds_Check:
		io.write_string(w, "bounds_check ") or_return
		write_element(w, v.array, v.index) or_return
		io.write_string(w, " not_integer ") or_return
		io.write_int(w, int(v.not_integer)) or_return
		io.write_string(w, " out_of_range ") or_return
		io.write_int(w, int(v.out_of_range)) or_return

	case Element_Load:
		io.write_string(w, "element_load ") or_return
		write_element(w, v.array, v.index) or_return

	case Element_Store:
		io.write_string(w, "element_store ") or_return
		write_element(w, v.array, v.index) or_return
		io.write_string(w, " = ") or_return
		write_value(w, v.value) or_return

	case Element_Store_Ref:
		io.write_string(w, "element_store_ref ") or_return
		write_element(w, v.array, v.index) or_return
		io.write_string(w, " = ") or_return
		write_value(w, v.value) or_return

	case Layout_Test:
		io.write_string(w, "layout_test ") or_return
		write_value(w, v.cell) or_return
		io.write_byte(w, ' ') or_return
		io.write_int(w, int(v.layout)) or_return

	case Null_Test:
		io.write_string(w, "null_test ") or_return
		write_value(w, v.value) or_return

	case Tag_Test:
		io.write_string(w, "tag_test ") or_return
		write_value(w, v.value) or_return
		io.write_byte(w, ' ') or_return
		first := true
		for tag in v.tags {
			if !first {
				io.write_byte(w, '|') or_return
			}
			io.write_string(w, TAG_TEXT[tag]) or_return
			first = false
		}

	case Box:
		io.write_string(w, "box ") or_return
		write_value(w, v.value) or_return

	case Unbox:
		io.write_string(w, "unbox ") or_return
		write_value(w, v.value) or_return

	case Global_Load:
		io.write_string(w, "global_load ") or_return
		io.write_int(w, int(v.global)) or_return

	case Global_Store:
		io.write_string(w, "global_store ") or_return
		io.write_int(w, int(v.global)) or_return
		io.write_string(w, " = ") or_return
		write_value(w, v.value) or_return

	case Env:
		io.write_string(w, "env") or_return

	case Func_Ref:
		io.write_string(w, "func_ref ") or_return
		io.write_int(w, int(v.func)) or_return

	case Make_Closure:
		io.write_string(w, "make_closure ") or_return
		io.write_int(w, int(v.func)) or_return
		io.write_byte(w, '(') or_return
		if v.env != NO_VALUE {
			write_value(w, v.env) or_return
		}
		io.write_byte(w, ')') or_return

	case Call:
		io.write_string(w, "call ") or_return
		io.write_int(w, int(v.func)) or_return
		write_arguments(w, v.args) or_return

	case Call_Closure:
		io.write_string(w, "call_closure ") or_return
		write_value(w, v.callee) or_return
		write_arguments(w, v.args) or_return

	case Call_Runtime:
		exports := abi.RUNTIME_EXPORTS
		io.write_string(w, "call_runtime ") or_return
		io.write_string(w, exports[v.export].symbol) or_return
		write_arguments(w, v.args) or_return

	case Intrinsic:
		io.write_string(w, "intrinsic ") or_return
		io.write_string(w, INTRINSIC_TEXT[v.op]) or_return
		write_arguments(w, v.args) or_return

	case Jump:
		io.write_string(w, "jump b") or_return
		io.write_int(w, int(v.target)) or_return

	case Branch:
		io.write_string(w, "branch ") or_return
		write_value(w, v.condition) or_return
		io.write_string(w, " b") or_return
		io.write_int(w, int(v.then_block)) or_return
		io.write_string(w, " b") or_return
		io.write_int(w, int(v.else_block)) or_return

	case Return:
		io.write_string(w, "return") or_return
		if v.value != NO_VALUE {
			io.write_byte(w, ' ') or_return
			write_value(w, v.value) or_return
		}

	case Fail:
		io.write_string(w, "fail ") or_return
		io.write_int(w, int(v.site)) or_return
	}
	return nil
}

@(private)
write_arguments :: proc(w: io.Writer, args: []Value_ID) -> io.Error {
	io.write_byte(w, '(') or_return
	for arg, i in args {
		if i > 0 {
			io.write_string(w, ", ") or_return
		}
		write_value(w, arg) or_return
	}
	io.write_byte(w, ')') or_return
	return nil
}

@(private)
write_field :: proc(w: io.Writer, cell: Value_ID, field: i32) -> io.Error {
	write_value(w, cell) or_return
	io.write_string(w, " field ") or_return
	io.write_int(w, int(field)) or_return
	return nil
}

@(private)
write_element :: proc(w: io.Writer, array, index: Value_ID) -> io.Error {
	write_value(w, array) or_return
	io.write_byte(w, '[') or_return
	write_value(w, index) or_return
	io.write_byte(w, ']') or_return
	return nil
}

@(private)
write_value :: proc(w: io.Writer, id: Value_ID) -> io.Error {
	if id == NO_VALUE {
		io.write_string(w, "%none") or_return
		return nil
	}
	io.write_byte(w, '%') or_return
	io.write_int(w, int(id)) or_return
	return nil
}

@(private)
write_type :: proc(w: io.Writer, type: Type) -> io.Error {
	if type.kind != .Ref {
		io.write_string(w, TYPE_KIND_TEXT[type.kind]) or_return
		return nil
	}
	io.write_string(w, "ref(") or_return
	io.write_int(w, int(type.layout)) or_return
	io.write_byte(w, ')') or_return
	return nil
}

// write_number writes the shortest decimal that reads back as the same f64, so a dump shows exactly
// the value the program holds: -0, NaN and Inf included. The ECMAScript rules for turning a number
// into a string belong to the runtime, not to a debugging artifact.
//
// Plain decimal, never an exponent, as in the numbers a diagnostic shows: a program is written in
// ordinary numbers, and `1e+06` in place of a million helps nobody. The buffer holds the longest
// such decimal, which is the smallest denormal at some 330 characters.
@(private)
write_number :: proc(w: io.Writer, value: f64) -> io.Error {
	buf: [384]byte
	text := strconv.write_float(buf[:], value, 'f', -1, 64)
	// strconv signs every number it writes; only a negative one keeps its sign here.
	if len(text) > 0 && text[0] == '+' {
		text = text[1:]
	}
	io.write_string(w, text) or_return
	return nil
}

// write_place writes ` at <path>:<line>:<column>`, the place a whole function or a violation points
// at.
@(private)
write_place :: proc(w: io.Writer, files: []source.File, span: source.Span) -> io.Error {
	io.write_string(w, " at ") or_return
	if int(span.file) < len(files) {
		io.write_string(w, files[span.file].path) or_return
	} else {
		io.write_byte(w, '?') or_return
	}
	io.write_byte(w, ':') or_return
	write_position(w, files, span) or_return
	return nil
}

// write_position writes `<line>:<column>` for the start of a span. A span of a file the table does
// not hold prints as question marks rather than stopping the dump: a broken layer is what a dump is
// read for.
@(private)
write_position :: proc(w: io.Writer, files: []source.File, span: source.Span) -> io.Error {
	if !placed(files, span) {
		io.write_string(w, "?:?") or_return
		return nil
	}
	position := source.position(files[span.file], span.start)
	io.write_int(w, int(position.line)) or_return
	io.write_byte(w, ':') or_return
	io.write_int(w, int(position.column)) or_return
	return nil
}

// placed is asked first instead of trusting the span: source.position asserts on an offset outside
// its file, and a dump is read precisely when a layer is broken.
@(private)
placed :: proc(files: []source.File, span: source.Span) -> bool {
	if int(span.file) >= len(files) {
		return false
	}
	return span.start >= 0 && int(span.start) <= len(files[span.file].text)
}

// write_text quotes a name the program wrote, which is UTF-8 and stays as it is apart from the two
// characters that would end the quotes and the control bytes that would break the line.
@(private)
write_text :: proc(w: io.Writer, text: string) -> io.Error {
	io.write_byte(w, '"') or_return
	for i in 0 ..< len(text) {
		unit := text[i]
		switch {
		case unit == '"' || unit == '\\':
			io.write_byte(w, '\\') or_return
			io.write_byte(w, unit) or_return
		case unit < 0x20 || unit == 0x7F:
			io.write_string(w, "\\x") or_return
			write_hex(w, u16(unit), 2) or_return
		case:
			io.write_byte(w, unit) or_return
		}
	}
	io.write_byte(w, '"') or_return
	return nil
}

// write_units quotes a string constant unit by unit. The pool holds UTF-16 and keeps a lone
// surrogate the program wrote, so decoding it into runes here would turn that unit into U+FFFD and
// the dump would no longer show what codegen emits.
@(private)
write_units :: proc(w: io.Writer, units: []u16) -> io.Error {
	io.write_byte(w, '"') or_return
	for unit in units {
		switch {
		case unit == '"' || unit == '\\':
			io.write_byte(w, '\\') or_return
			io.write_byte(w, u8(unit)) or_return
		case unit >= 0x20 && unit < 0x7F:
			io.write_byte(w, u8(unit)) or_return
		case:
			io.write_string(w, "\\u") or_return
			write_hex(w, unit, 4) or_return
		}
	}
	io.write_byte(w, '"') or_return
	return nil
}

@(private)
write_hex :: proc(w: io.Writer, value: u16, digits: int) -> io.Error {
	for shift := (digits - 1) * 4; shift >= 0; shift -= 4 {
		io.write_byte(w, HEX_DIGITS[(value >> uint(shift)) & 0xF]) or_return
	}
	return nil
}

// @(rodata) rather than a constant: Odin indexes a constant only by a constant, and the index here
// is a nibble of the value being written.
@(private, rodata)
HEX_DIGITS := "0123456789abcdef"

@(private, rodata)
TYPE_KIND_TEXT := [Type_Kind]string {
	.Void    = "void",
	.F64     = "f64",
	.Bool    = "bool",
	.Tagged  = "tagged",
	.Str     = "str",
	.Closure = "closure",
	.Ref     = "ref",
}

@(private, rodata)
BINARY_TEXT := [Binary_Op]string {
	.Add                  = "add",
	.Subtract             = "sub",
	.Multiply             = "mul",
	.Divide               = "div",
	.Remainder            = "rem",
	.Power                = "pow",
	.Shift_Left           = "shl",
	.Shift_Right          = "shr",
	.Shift_Right_Unsigned = "ushr",
	.Bit_And              = "bit_and",
	.Bit_Or               = "bit_or",
	.Bit_Xor              = "bit_xor",
}

@(private, rodata)
UNARY_TEXT := [Unary_Op]string {
	.Negate  = "neg",
	.Not     = "not",
	.Bit_Not = "bit_not",
}

@(private, rodata)
COMPARE_TEXT := [Compare_Op]string {
	.Less          = "lt",
	.Less_Equal    = "le",
	.Greater       = "gt",
	.Greater_Equal = "ge",
	.Equal         = "eq",
	.Not_Equal     = "ne",
}

@(private, rodata)
INTRINSIC_TEXT := [Intrinsic_Op]string {
	.Abs   = "abs",
	.Sqrt  = "sqrt",
	.Floor = "floor",
	.Ceil  = "ceil",
	.Trunc = "trunc",
	.Sin   = "sin",
	.Cos   = "cos",
	.Tan   = "tan",
	.Asin  = "asin",
	.Acos  = "acos",
	.Atan  = "atan",
	.Atan2 = "atan2",
	.Sinh  = "sinh",
	.Cosh  = "cosh",
	.Tanh  = "tanh",
	.Asinh = "asinh",
	.Acosh = "acosh",
	.Atanh = "atanh",
	.Exp   = "exp",
	.Expm1 = "expm1",
	.Log   = "log",
	.Log1p = "log1p",
	.Log2  = "log2",
	.Log10 = "log10",
	.Cbrt  = "cbrt",
}

@(private, rodata)
TAG_TEXT := [abi.Tag]string {
	.Undefined = "undefined",
	.Null      = "null",
	.Boolean   = "boolean",
	.Number    = "number",
	.String    = "string",
	.Object    = "object",
	.Function  = "function",
}

@(private, rodata)
SLOT_KIND_TEXT := [abi.Slot_Kind]string {
	.Number  = "number",
	.Boolean = "boolean",
	.Ref     = "ref",
	.Tagged  = "tagged",
}

@(private, rodata)
CELL_KIND_TEXT := [abi.Cell_Kind]string {
	.Object      = "object",
	.Environment = "environment",
	.String      = "string",
	.Array       = "array",
	.Closure     = "closure",
	.Buffer      = "buffer",
}

@(private, rodata)
RUNTIME_ERROR_TEXT := [abi.Runtime_Error]string {
	.Index_Out_Of_Range           = "index_out_of_range",
	.Index_Not_Integer            = "index_not_integer",
	.Non_Null_Assertion           = "non_null_assertion",
	.Type_Assertion               = "type_assertion",
	.Out_Of_Memory                = "out_of_memory",
	.Internal                     = "internal",
	.Exit_Code_Not_Integer        = "exit_code_not_integer",
	.Fraction_Digits_Out_Of_Range = "fraction_digits_out_of_range",
	.Not_Convertible_To_String    = "not_convertible_to_string",
	.Invalid_String_Length        = "invalid_string_length",
	.Not_Convertible_To_Number    = "not_convertible_to_number",
	.Not_Convertible_To_Json      = "not_convertible_to_json",
	.Reduce_Of_Empty_Array        = "reduce_of_empty_array",
	.Field_Holds_Other_Kind       = "field_holds_other_kind",
	.Value_Of_Other_Kind          = "value_of_other_kind",
	.Tagged_Holds_Other_Kind      = "tagged_holds_other_kind",
	.Read_Before_Initialization   = "read_before_initialization",
}

@(private, rodata)
VIOLATION_TEXT := [Violation_Kind]string {
	.Missing_Body          = "a function that was declared and never built",
	.Missing_Terminator    = "a block that does not end in a terminator",
	.Misplaced_Terminator  = "a terminator that is not the last instruction of its block",
	.Misplaced_Phi         = "a phi that does not stand before every other instruction",
	.Unknown_Value         = "an operand that names no instruction of this function",
	.Use_Before_Definition = "an operand whose definition does not reach every path to this use",
	.Unknown_Block         = "a block that is not in this function",
	.Phi_Edges             = "the edges of a phi that do not match the predecessors of its block",
	.Operand_Type          = "an operand of a kind this instruction cannot take",
	.Result_Type           = "a result type that does not suit this instruction",
	.Argument_Count        = "the wrong number of arguments",
	.Store_Kind            = "a store that does not match the slot it writes",
	.Unchecked_Index       = "an index that is not the answer of a bounds check of its array",
	.Unknown_Id            = "a layout, global, string, fail site or function that is not there",
	.Entry_Signature       = "an entry point that does not take nothing and return void",
	.Environment           = "an environment that does not match its function",
}
