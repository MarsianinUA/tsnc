package ir

import "core:math"

import "../abi"

/*
Checking a Program_IR against the contract in the package doc: single static assignment, a
terminator in every block, operand and result types that suit each instruction, and a reference into
a heap cell only through a store whose name ends in _Ref.

A violation is a bug in lower or opt, never a mistake in the TypeScript program, so it is not a
diag.Diagnostic: ir does not depend on diag and nothing here prints. verify answers every violation
it finds rather than stopping at the first, the way a phase returns every diagnostic it found, and
it never panics on a malformed program: a broken layer must still be reportable and printable.

Definition before use is dominance, not the order the values were emitted in. So verify asks the
Flow of the function whether the block that defines a value lies on every path to the block that
uses it. A phi operand is checked at the end of the block its edge names instead, which is what
makes a back edge legal.

A block nothing reaches is not a violation: the builder opens one after every terminator, so the
statements that follow a return land somewhere. Its instructions are still checked for shape and
types; only the dominance question is skipped there, because it has no answer.
*/

Violation_Kind :: enum u8 {
	Missing_Body, // a function that was declared and never built
	Missing_Terminator, // a block that is empty or does not end in a terminator
	Misplaced_Terminator, // a terminator that is not the last instruction of its block
	Misplaced_Phi, // a phi that does not stand before every other instruction of its block
	Unknown_Value, // an operand naming no instruction of this function
	Use_Before_Definition, // a definition that does not reach every path to the use
	Unknown_Block, // a jump, a branch or a phi edge naming a block that is not there
	Phi_Edges, // the edges of a phi do not match the predecessors of its block
	Operand_Type, // an operand, or the layout an instruction names, of a kind it cannot take
	Result_Type, // a result type that does not suit the instruction
	Argument_Count, // a call or an intrinsic with the wrong number of arguments
	Store_Kind, // a store that does not match the slot it writes
	Unchecked_Index, // an element access whose index is not the answer of a bounds check of its array
	Unknown_Id, // a layout, global, string, fail site or function that is not in the program
	Entry_Signature, // an entry point that does not take nothing and return void
	// An environment that does not match the function: an Env in a function without one, an env
	// that is no Environment layout, a direct call or a Func_Ref of a function with one, a
	// Make_Closure env operand that does not match it, a closure of the entry point or of an
	// undescribed function, an entry point with one. A box and a one-slot environment intern to one
	// layout, so which of the two a value is escapes this check; lower owns that.
	Environment,
}

// Violation has block NO_BLOCK and value NO_VALUE when nothing smaller than the function is at
// fault, as for an entry point with the wrong signature.
Violation :: struct {
	kind:  Violation_Kind,
	func:  Func_ID,
	block: Block_ID,
	value: Value_ID,
}

// verify answers every way p breaks its contract, in program order: the functions in Func_ID order,
// their blocks in Block_ID order, the instructions in block order, and the entry points last. The
// slice comes from allocator. The tables verify builds while it walks a function are scratch and
// come from context.temp_allocator; verify allocates from it and never resets it, which belongs to
// whoever owns the frame.
@(require_results)
verify :: proc(p: Program_IR, allocator := context.allocator) -> []Violation {
	c := Checker {
		program = p,
		found   = make([dynamic]Violation, allocator),
	}
	for id in 0 ..< len(p.funcs) {
		verify_func(&c, Func_ID(id))
	}
	verify_entry_points(&c)
	return c.found[:]
}

// Checker keeps in func, block and value the place a violation found below is reported at: an
// instruction check names no place of its own, so the walk sets the place before it runs the check.
@(private)
Checker :: struct {
	program:  Program_IR,
	found:    [dynamic]Violation,
	body:     Func,
	flow:     Flow,
	places:   []Place, // by Value_ID
	func:     Func_ID,
	block:    Block_ID,
	position: int,
	value:    Value_ID,
}

@(private)
verify_func :: proc(c: ^Checker, id: Func_ID) {
	c.func = id
	c.body = c.program.funcs[id]
	c.block = NO_BLOCK
	c.value = NO_VALUE

	if c.body.env != NO_LAYOUT {
		if table, known := layout_of(c, c.body.env); !known {
			report(c, .Unknown_Id)
		} else if table.kind != .Environment {
			report(c, .Environment)
		}
	}

	blocks := len(c.body.blocks)
	values := len(c.body.values)
	if blocks == 0 {
		// declare_func reserved the row and nothing ever filled it: there is no entry block to
		// enter and nothing below has anything to walk.
		report(c, .Missing_Body)
		return
	}
	c.places = locate_values(c.body, context.temp_allocator)
	report_unknown_values(c)
	verify_blocks(c)
	c.flow = make_flow(c.body, context.temp_allocator)

	for block in 0 ..< blocks {
		c.block = Block_ID(block)
		for value, position in c.body.blocks[block].instructions {
			if int(value) >= values {
				continue // report_unknown_values reported it; there is no instruction to check
			}
			c.position = position
			c.value = value
			verify_instruction(c)
		}
	}
}

@(private)
report_unknown_values :: proc(c: ^Checker) {
	for block, index in c.body.blocks {
		c.block = Block_ID(index)
		for value in block.instructions {
			if int(value) >= len(c.body.values) {
				c.value = value
				report(c, .Unknown_Value)
			}
		}
	}
}

@(private)
verify_blocks :: proc(c: ^Checker) {
	for block, index in c.body.blocks {
		c.block = Block_ID(index)
		c.value = NO_VALUE
		if len(block.instructions) == 0 {
			report(c, .Missing_Terminator)
			continue
		}

		body_seen := false // a phi after any other instruction stands in the wrong place
		for value, position in block.instructions {
			if int(value) >= len(c.body.values) {
				continue
			}
			c.value = value
			variant := c.body.values[value].variant
			if terminates(variant) && position != len(block.instructions) - 1 {
				report(c, .Misplaced_Terminator)
			}
			if _, is_phi := variant.(Phi); is_phi {
				if body_seen {
					report(c, .Misplaced_Phi)
				}
			} else {
				body_seen = true
			}
		}

		c.value = NO_VALUE
		last := block.instructions[len(block.instructions) - 1]
		if int(last) >= len(c.body.values) || !terminates(c.body.values[last].variant) {
			report(c, .Missing_Terminator)
		}
	}
}

// verify_instruction is the same exhaustive switch codegen is: a variant added to the union without
// a case here fails the build.
@(private)
verify_instruction :: proc(c: ^Checker) {
	instruction := c.body.values[c.value]
	if instruction.type.nullish != .None && !is_reference(instruction.type) {
		report(c, .Result_Type)
	}
	switch v in instruction.variant {
	case Unreachable:
		expect_result(c, VOID)

	case Param:
		if int(v.index) < 0 || int(v.index) >= len(c.body.params) {
			report(c, .Unknown_Id)
			return
		}
		expect_result(c, c.body.params[v.index])

	case Const_Number:
		type := instruction.type
		if type != F64 && !(is_integer(type) && holds_integer(type, v.value)) {
			report(c, .Result_Type)
		}

	case Const_Bool:
		expect_result(c, BOOL)

	case Const_Undefined:
		expect_result(c, TAGGED)

	case Const_Null:
		type := instruction.type
		if type.kind == .Ref {
			if _, known := layout_of(c, type.layout); !known {
				report(c, .Unknown_Id)
			}
		} else if type != TAGGED && !is_reference(type) {
			report(c, .Result_Type)
		}

	case Const_String:
		if int(v.text) >= len(c.program.strings) {
			report(c, .Unknown_Id)
		}
		expect_result(c, STR)

	case Binary:
		switch v.op {
		case .Add, .Subtract, .Multiply, .Remainder:
			expect_arithmetic(c, {v.left, v.right})
		case .Divide, .Power:
			expect_operand(c, v.left, F64)
			expect_operand(c, v.right, F64)
			expect_result(c, F64)
		case .Shift_Left, .Shift_Right, .Bit_And, .Bit_Or, .Bit_Xor:
			expect_bitwise(c, {v.left, v.right}, I32)
		case .Shift_Right_Unsigned:
			expect_bitwise(c, {v.left, v.right}, I64)
		}

	case Unary:
		switch v.op {
		case .Not:
			expect_operand(c, v.operand, BOOL)
			expect_result(c, BOOL)
		case .Negate:
			expect_arithmetic(c, {v.operand})
		case .Bit_Not:
			expect_bitwise(c, {v.operand}, I32)
		}

	case Compare:
		left, left_known := operand(c, v.left)
		right, right_known := operand(c, v.right)
		if left_known && right_known {
			ordered := v.op != .Equal && v.op != .Not_Equal
			if !comparable(left, right) || (ordered && !is_number(left)) {
				report(c, .Operand_Type)
			}
		}
		expect_result(c, BOOL)

	case Phi:
		if instruction.type == VOID {
			report(c, .Result_Type)
		}
		if c.flow.rank[c.block] >= 0 && !edges_match(c, v.incoming) {
			report(c, .Phi_Edges)
		}
		for edge in v.incoming {
			verify_edge(c, edge, instruction.type)
		}

	case Convert:
		type, known := operand(c, v.value)
		result := instruction.type
		if !is_number(result) {
			report(c, .Result_Type)
		} else if known && !converts(type, result) {
			report(c, .Operand_Type)
		}

	case Alloc:
		table, known := layout_of(c, v.layout)
		if !known {
			report(c, .Unknown_Id)
			return
		}
		if table.kind != .Object && table.kind != .Environment || !is_base(c, v.layout) {
			report(c, .Operand_Type)
		}
		if v.table != NO_LAYOUT {
			if _, row_known := layout_of(c, v.table); !row_known {
				report(c, .Unknown_Id)
			} else if c.program.base[v.table] != v.layout {
				report(c, .Operand_Type)
			}
		}
		expect_result(c, ref(v.layout))

	case New_Array:
		table, known := layout_of(c, v.layout)
		if !known {
			report(c, .Unknown_Id)
			return
		}
		if table.kind != .Array {
			report(c, .Operand_Type)
		}
		expect_operand(c, v.length, F64)
		// codegen sizes the slot of an array on the stack by its constant length.
		if _, fits := cell_size(c.program, c.body, c.value); v.place == .Stack && !fits {
			report(c, .Operand_Type)
		}
		expect_result(c, ref(v.layout))

	case Field_Load:
		field, known := field_of(c, v.cell, v.field)
		if known && !slot_holds(field.kind, instruction.type) {
			report(c, .Result_Type)
		}

	case Field_Store:
		field, known := field_of(c, v.cell, v.field)
		if known {
			if traced(field.kind) {
				report(c, .Store_Kind)
			}
			expect_slot(c, v.value, field.kind)
		}
		expect_result(c, VOID)

	case Field_Store_Ref:
		field, known := field_of(c, v.cell, v.field)
		if known {
			if !traced(field.kind) {
				report(c, .Store_Kind)
			}
			expect_slot(c, v.value, field.kind)
		}
		expect_result(c, VOID)

	case Length:
		// A string or an array: element_of reports anything else, and the kind is nothing here.
		if type, known := operand(c, v.value); known && type != STR {
			element_of(c, type)
		}
		expect_result_of(c, {F64, I64})

	case Bounds_Check:
		if type, known := operand(c, v.array); known && type != STR {
			element_of(c, type)
		}
		expect_index(c, v.index)
		if !v.proved {
			expect_site(c, v.not_integer)
			expect_site(c, v.out_of_range)
		}

	case Element_Load:
		element, known := array_element(c, v.array)
		expect_checked_index(c, v.index, v.array)
		if known && !slot_holds(element, instruction.type) {
			report(c, .Result_Type)
		}

	case Element_Store:
		element, known := array_element(c, v.array)
		expect_checked_index(c, v.index, v.array)
		if known {
			if traced(element) {
				report(c, .Store_Kind)
			}
			expect_slot(c, v.value, element)
		}
		expect_result(c, VOID)

	case Element_Store_Ref:
		element, known := array_element(c, v.array)
		expect_checked_index(c, v.index, v.array)
		if known {
			if !traced(element) {
				report(c, .Store_Kind)
			}
			expect_slot(c, v.value, element)
		}
		expect_result(c, VOID)

	case Unit_Load:
		expect_operand(c, v.text, STR)
		expect_checked_index(c, v.index, v.text)
		expect_result_of(c, {F64, I32})

	case Ascii_Cell:
		if _, known := operand(c, v.unit); known {
			if _, loaded := c.body.values[v.unit].variant.(Unit_Load); !loaded {
				report(c, .Operand_Type)
			}
		}
		expect_result(c, STR)

	case Layout_Test:
		cell, cell_known := operand(c, v.cell)
		if cell_known && (cell.kind != .Ref || cell.nullish != .None) {
			report(c, .Operand_Type)
		}
		if _, known := layout_of(c, v.layout); !known {
			report(c, .Unknown_Id)
		} else if !is_base(c, v.layout) {
			report(c, .Operand_Type)
		}
		expect_result(c, BOOL)

	case Null_Test:
		if type, known := operand(c, v.value); known && !is_reference(type) {
			report(c, .Operand_Type)
		}
		expect_result(c, BOOL)

	case Non_Null:
		if type, known := operand(c, v.value); known {
			if !is_reference(type) || type.nullish == .None {
				report(c, .Operand_Type)
			}
			expect_result(c, non_null(type))
		}

	case Same_Cell:
		a, a_known := operand(c, v.a)
		b, b_known := operand(c, v.b)
		if a_known && b_known && (a != STR || b != STR) {
			report(c, .Operand_Type)
		}
		expect_result(c, BOOL)

	case Tag_Test:
		expect_operand(c, v.value, TAGGED)
		expect_result(c, BOOL)

	case Box:
		type, known := operand(c, v.value)
		if known && !boxable(type) {
			report(c, .Operand_Type)
		}
		expect_result(c, TAGGED)

	case Unbox:
		expect_operand(c, v.value, TAGGED)
		if instruction.type == VOID || instruction.type == TAGGED || is_integer(instruction.type) {
			report(c, .Result_Type)
		}

	case Global_Load:
		global, known := global_of(c, v.global)
		if !known {
			return
		}
		expect_result(c, global.type)

	case Global_Store:
		global, known := global_of(c, v.global)
		if !known {
			return
		}
		expect_operand(c, v.value, global.type)
		expect_result(c, VOID)

	case Env:
		if c.body.env == NO_LAYOUT {
			report(c, .Environment)
			return
		}
		expect_result(c, ref(c.body.env))

	case Func_Ref:
		callee, known := closure_of(c, v.func)
		if known && callee.env != NO_LAYOUT {
			report(c, .Environment)
		}
		expect_result(c, CLOSURE)

	case Make_Closure:
		callee, known := closure_of(c, v.func)
		switch {
		case !known:
		case callee.env == NO_LAYOUT:
			if v.env != NO_VALUE {
				report(c, .Environment)
			}
		case v.env == NO_VALUE:
			report(c, .Environment)
		case:
			if type, env_known := operand(c, v.env); env_known && type != ref(callee.env) {
				report(c, .Environment)
			}
		}
		expect_result(c, CLOSURE)

	case Call:
		if int(v.func) >= len(c.program.funcs) {
			report(c, .Unknown_Id)
			return
		}
		callee := c.program.funcs[v.func]
		if callee.env != NO_LAYOUT {
			report(c, .Environment)
		}
		if len(v.args) != len(callee.params) {
			report(c, .Argument_Count)
		}
		for arg, i in v.args {
			if i < len(callee.params) {
				expect_operand(c, arg, callee.params[i])
			}
		}
		expect_result(c, callee.result)

	case Call_Closure:
		expect_operand(c, v.callee, CLOSURE)
		// A callee whose function is known has to get its parameters: escape reads them by index.
		if callee, known := closure_target(c, v.callee); known {
			if len(v.args) != len(c.program.funcs[callee].params) {
				report(c, .Argument_Count)
			}
		}
		for arg in v.args {
			// A function value carries no signature, so only the arguments themselves are checked:
			// codegen builds the signature out of their types, and a parameter is never an integer.
			if type, known := operand(c, arg); known && is_integer(type) {
				report(c, .Operand_Type)
			}
		}
		if is_integer(instruction.type) {
			report(c, .Result_Type)
		}

	case Call_Runtime:
		exports := abi.RUNTIME_EXPORTS
		export := exports[v.export]
		// A trailing Rest takes every argument past the fixed ones, and each of them is Tagged.
		fixed := export.params
		rest := len(fixed) > 0 && fixed[len(fixed) - 1] == .Rest
		if rest {
			fixed = fixed[:len(fixed) - 1]
		}
		if len(v.args) < len(fixed) || !rest && len(v.args) != len(fixed) {
			report(c, .Argument_Count)
		}
		for arg, i in v.args {
			type, known := operand(c, arg)
			switch {
			case !known:
			case i < len(fixed):
				if !c_type_fits(fixed[i], type) {
					report(c, .Operand_Type)
				}
			case rest && type != TAGGED:
				report(c, .Operand_Type)
			}
		}
		if !c_type_fits(export.result, instruction.type) {
			report(c, .Result_Type)
		}

	case Intrinsic:
		arity := 2 if v.op == .Atan2 else 1
		if len(v.args) != arity {
			report(c, .Argument_Count)
		}
		for arg in v.args {
			expect_operand(c, arg, F64)
		}
		expect_result(c, F64)

	case Jump:
		expect_block(c, v.target)
		expect_result(c, VOID)

	case Branch:
		expect_operand(c, v.condition, BOOL)
		expect_block(c, v.then_block)
		expect_block(c, v.else_block)
		expect_result(c, VOID)

	case Return:
		if c.body.result == VOID {
			if v.value != NO_VALUE {
				report(c, .Operand_Type)
			}
		} else if v.value == NO_VALUE {
			report(c, .Operand_Type)
		} else {
			expect_operand(c, v.value, c.body.result)
		}
		expect_result(c, VOID)

	case Fail:
		expect_site(c, v.site)
		expect_result(c, VOID)
	}
}

// verify_edge wants the value to be there at the end of the block the edge names, which is the
// block control came through, rather than before the phi itself.
@(private)
verify_edge :: proc(c: ^Checker, edge: Incoming, want: Type) {
	if int(edge.block) >= len(c.body.blocks) {
		report(c, .Unknown_Block)
		return
	}
	if int(edge.value) >= len(c.body.values) {
		report(c, .Unknown_Value)
		return
	}
	if c.flow.rank[edge.block] >= 0 && !reaches_end(c, edge.block, edge.value) {
		report(c, .Use_Before_Definition)
	}
	if !fits(c.body.values[edge.value].type, want) {
		report(c, .Operand_Type)
	}
}

// edges_match says whether a phi has exactly one edge per predecessor edge of its block, so a
// branch that names one block on both sides gets two.
@(private)
edges_match :: proc(c: ^Checker, incoming: []Incoming) -> bool {
	preds := c.flow.preds[c.block]
	if len(incoming) != len(preds) {
		return false
	}
	taken := make([]bool, len(incoming), context.temp_allocator)
	for pred in preds {
		matched := false
		for edge, i in incoming {
			if !taken[i] && edge.block == pred {
				taken[i] = true
				matched = true
				break
			}
		}
		if !matched {
			return false
		}
	}
	return true
}

// verify_entry_points checks what main calls and what codegen emits: the entry point itself, the
// module init functions in the order main runs them, and the functions of every unit.
@(private)
verify_entry_points :: proc(c: ^Checker) {
	c.block = NO_BLOCK
	c.value = NO_VALUE

	c.func = c.program.main
	if int(c.program.main) >= len(c.program.funcs) {
		report(c, .Unknown_Id)
	} else {
		expect_entry_signature(c, c.program.main)
	}
	for id in c.program.init_order {
		c.func = id
		if int(id) >= len(c.program.funcs) {
			report(c, .Unknown_Id)
			continue
		}
		expect_entry_signature(c, id)
	}
	for unit in c.program.units {
		for id in unit.funcs {
			c.func = id
			if int(id) >= len(c.program.funcs) {
				report(c, .Unknown_Id)
			}
		}
	}
}

@(private)
expect_entry_signature :: proc(c: ^Checker, id: Func_ID) {
	body := c.program.funcs[id]
	if len(body.params) != 0 || body.result != VOID {
		report(c, .Entry_Signature)
	}
	if body.env != NO_LAYOUT {
		report(c, .Environment)
	}
}

// closure_of answers the function a closure is made of. The entry point is none: the runtime calls
// it by its symbol, in a convention of its own.
@(private)
closure_of :: proc(c: ^Checker, id: Func_ID) -> (callee: Func, known: bool) {
	if int(id) >= len(c.program.funcs) {
		report(c, .Unknown_Id)
		return
	}
	callee = c.program.funcs[id]
	if id == c.program.main || callee.info == nil {
		report(c, .Environment)
	}
	return callee, true
}

// operand answers the type of a value the instruction being checked reads, and reports a value that
// is not there or whose definition does not reach the use. The type comes back even then, so one
// wrong operand does not hide the rest of the instruction.
@(private)
operand :: proc(c: ^Checker, id: Value_ID) -> (type: Type, known: bool) {
	if int(id) >= len(c.body.values) {
		report(c, .Unknown_Value)
		return
	}
	if c.flow.rank[c.block] >= 0 && !reaches(c, id) {
		report(c, .Use_Before_Definition)
	}
	return c.body.values[id].type, true
}

@(private)
expect_operand :: proc(c: ^Checker, id: Value_ID, want: Type) {
	type, known := operand(c, id)
	if known && !fits(type, want) {
		report(c, .Operand_Type)
	}
}

@(private)
expect_slot :: proc(c: ^Checker, id: Value_ID, kind: abi.Slot_Kind) {
	type, known := operand(c, id)
	if known && !slot_fits(kind, type) {
		report(c, .Operand_Type)
	}
}

// expect_checked_index keeps a check from drifting away from the access it guards.
@(private)
expect_checked_index :: proc(c: ^Checker, id: Value_ID, array: Value_ID) {
	type, known := operand(c, id)
	if !known {
		return
	}
	if !is_number(type) {
		report(c, .Operand_Type)
	}
	bounds, checked := c.body.values[id].variant.(Bounds_Check)
	if !checked || bounds.array != array {
		report(c, .Unchecked_Index)
	}
}

// expect_index: the answer of a check is the index itself, in its own type.
@(private)
expect_index :: proc(c: ^Checker, id: Value_ID) {
	type, known := operand(c, id)
	if !known {
		return
	}
	if !is_number(type) {
		report(c, .Operand_Type)
	} else {
		expect_result(c, type)
	}
}

@(private)
expect_arithmetic :: proc(c: ^Checker, ids: []Value_ID) {
	result := c.body.values[c.value].type
	if !is_number(result) {
		report(c, .Result_Type)
		return
	}
	for id in ids {
		expect_operand(c, id, result)
	}
}

// expect_bitwise takes any number type as an operand: ToInt32 reads each of them.
@(private)
expect_bitwise :: proc(c: ^Checker, ids: []Value_ID, integer: Type) {
	for id in ids {
		if type, known := operand(c, id); known && !is_number(type) {
			report(c, .Operand_Type)
		}
	}
	expect_result_of(c, {F64, integer})
}

@(private)
expect_result :: proc(c: ^Checker, want: Type) {
	if c.body.values[c.value].type != want {
		report(c, .Result_Type)
	}
}

@(private)
expect_result_of :: proc(c: ^Checker, wants: []Type) {
	for want in wants {
		if c.body.values[c.value].type == want {
			return
		}
	}
	report(c, .Result_Type)
}

@(private)
expect_block :: proc(c: ^Checker, block: Block_ID) {
	if int(block) >= len(c.body.blocks) {
		report(c, .Unknown_Block)
	}
}

@(private)
expect_site :: proc(c: ^Checker, site: Fail_Site_ID) {
	if int(site) >= len(c.program.fail_sites) {
		report(c, .Unknown_Id)
	}
}

@(private)
closure_target :: proc(c: ^Checker, callee: Value_ID) -> (func: Func_ID, known: bool) {
	if int(callee) >= len(c.body.values) {
		return 0, false
	}
	#partial switch v in c.body.values[callee].variant {
	case Make_Closure:
		func = v.func
	case Func_Ref:
		func = v.func
	case:
		return 0, false
	}
	return func, int(func) < len(c.program.funcs)
}

// reaches says whether the definition of a value is in hand where the instruction being checked
// stands: earlier in the same block, or in a block that dominates this one.
@(private)
reaches :: proc(c: ^Checker, id: Value_ID) -> bool {
	home := c.places[id]
	if home.block == NO_BLOCK {
		return false
	}
	if home.block == c.block {
		return home.position < c.position
	}
	return dominates(c.flow, home.block, c.block)
}

// reaches_end says whether the definition of a value is in hand at the end of a block, which is
// what an edge of a phi asks.
@(private)
reaches_end :: proc(c: ^Checker, block: Block_ID, id: Value_ID) -> bool {
	home := c.places[id].block
	if home == NO_BLOCK {
		return false
	}
	return home == block || dominates(c.flow, home, block)
}

@(private)
field_of :: proc(c: ^Checker, cell: Value_ID, index: i32) -> (field: abi.Field, known: bool) {
	type, cell_known := operand(c, cell)
	if !cell_known {
		return
	}
	if type.kind != .Ref || type.nullish != .None {
		report(c, .Operand_Type)
		return
	}
	table, found := layout_of(c, type.layout)
	if !found {
		report(c, .Unknown_Id)
		return
	}
	if int(index) < 0 || int(index) >= len(table.fields) {
		report(c, .Unknown_Id)
		return
	}
	return table.fields[index], true
}

@(private)
array_element :: proc(c: ^Checker, array: Value_ID) -> (element: abi.Slot_Kind, known: bool) {
	type, array_known := operand(c, array)
	if !array_known {
		return
	}
	return element_of(c, type)
}

// element_of reports a type that is not an array.
@(private)
element_of :: proc(c: ^Checker, type: Type) -> (element: abi.Slot_Kind, known: bool) {
	if type.kind != .Ref || type.nullish != .None {
		report(c, .Operand_Type)
		return
	}
	table, found := layout_of(c, type.layout)
	if !found {
		report(c, .Unknown_Id)
		return
	}
	if table.kind != .Array {
		report(c, .Operand_Type)
		return
	}
	return table.element, true
}

@(private)
global_of :: proc(c: ^Checker, id: Global_ID) -> (global: Global, known: bool) {
	if int(id) >= len(c.program.globals) {
		report(c, .Unknown_Id)
		return
	}
	return c.program.globals[id], true
}

@(private)
layout_of :: proc(c: ^Checker, id: Layout_ID) -> (table: abi.Type_Table, known: bool) {
	if id == NO_LAYOUT || int(id) >= len(c.program.layouts) {
		return
	}
	return c.program.layouts[id], true
}

// is_base says whether a known layout is a layout of its own rather than a table row that reorders
// one: a type and an instruction name the layout, only a cell header names a row.
@(private)
is_base :: proc(c: ^Checker, id: Layout_ID) -> bool {
	return int(id) < len(c.program.base) && c.program.base[id] == id
}

// slot_holds is what a load from a slot of this kind answers. A reference slot holds any reference:
// abi.Field carries a slot kind and not a table of its own, so the layout behind a traced slot is
// not knowable here.
@(private)
slot_holds :: proc(kind: abi.Slot_Kind, type: Type) -> bool {
	switch kind {
	case .Number:
		return type == F64
	case .Boolean:
		return type == BOOL
	case .Ref:
		return is_reference(type) && type.nullish == .None
	case .Ref_Or_Null:
		return is_reference(type) && type.nullish == .Null
	case .Ref_Or_Undefined:
		return is_reference(type) && type.nullish == .Undefined
	case .Tagged:
		return type == TAGGED
	}
	return false
}

// slot_fits is what a store may write: what the slot holds, or a present reference into a slot that
// may hold null.
@(private)
slot_fits :: proc(kind: abi.Slot_Kind, type: Type) -> bool {
	nullable_slot := kind == .Ref_Or_Null || kind == .Ref_Or_Undefined
	return slot_holds(kind, type) || nullable_slot && is_reference(type) && type.nullish == .None
}

// c_type_fits lets a Ptr take any present reference, because an export names no layout of its own
// and dereferences what it is given.
@(private)
c_type_fits :: proc(kind: abi.C_Type, type: Type) -> bool {
	switch kind {
	case .Void:
		return type == VOID
	case .Ptr:
		return is_reference(type) && type.nullish == .None
	case .Number:
		return type == F64
	case .Boolean:
		return type == BOOL
	case .Tagged:
		return type == TAGGED
	case .Rest:
	// Not one operand: the Call_Runtime case checks each of them as a Tagged.
	case .Table:
	// No IR value is a table: codegen passes one itself, from the layout of Alloc or New_Array.
	}
	return false
}

// comparable says whether Equal and Not_Equal compare two values themselves. A string and a tagged
// value go through the runtime instead: one holds its contents, the other its tag. Two objects or
// two functions compare addresses, except where 0 is null on one side and undefined on the other.
@(private)
comparable :: proc(left, right: Type) -> bool {
	if is_number(left) || left == BOOL {
		return left == right
	}
	if left.kind != .Ref && left.kind != .Closure || non_null(left) != non_null(right) {
		return false
	}
	return left.nullish == right.nullish || left.nullish == .None || right.nullish == .None
}

// holds_integer refuses -0, which no integer stands for.
@(private)
holds_integer :: proc(type: Type, value: f64) -> bool {
	if value != math.trunc(value) || value == 0 && math.sign_bit(value) {
		return false
	}
	if type == I32 {
		return value >= -(1 << 31) && value <= (1 << 31) - 1
	}
	return value >= -(1 << 63) && value < (1 << 63)
}

@(private)
converts :: proc(from, to: Type) -> bool {
	switch from {
	case I32:
		return to == I64 || to == F64
	case I64:
		return to == F64
	case F64:
		return is_integer(to)
	}
	return false
}

@(private)
boxable :: proc(type: Type) -> bool {
	return type == F64 || type == BOOL || is_reference(type)
}

@(private)
report :: proc(c: ^Checker, kind: Violation_Kind) {
	append(&c.found, Violation{kind = kind, func = c.func, block = c.block, value = c.value})
}
