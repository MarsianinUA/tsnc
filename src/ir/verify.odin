package ir

import "../abi"

/*
Checking a Program_IR against the contract in the package doc: single static assignment, a
terminator in every block, operand and result types that suit each instruction, and a reference into
a heap cell only through a store whose name ends in _Ref.

A violation is a bug in lower or opt, never a mistake in the TypeScript program, so it is not a
diag.Diagnostic: ir does not depend on diag and nothing here prints. verify answers every violation
it finds rather than stopping at the first, the way a phase returns every diagnostic it found, and
it never panics on a malformed program: a broken layer must still be reportable and printable.

Definition before use is dominance, not the order the values were emitted in. A Value_ID is numbered
when its instruction was emitted, which crosses block boundaries, and a loop header receives its phi
before the body that feeds it. So verify builds the predecessors of every block, walks them in
reverse post-order, builds the dominator tree from that order and asks whether the block that
defines a value lies on every path to the block that uses it. A phi operand is checked at the end of
the block its edge names instead, which is what makes a back edge legal.

A block nothing reaches is not a violation: the builder opens one after every terminator, so the
statements that follow a return land somewhere. Its instructions are still checked for shape and
types; only the dominance question is skipped there, because it has no answer.
*/

// Violation_Kind names one way a Program_IR breaks its contract.
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
	Unchecked_Index, // an element access whose index is not the answer of a bounds check
	Unknown_Id, // a layout, global, string, fail site or function that is not in the program
	Entry_Signature, // an entry point that does not take nothing and return void
}

// Violation is one finding. block is NO_BLOCK and value is NO_VALUE when nothing smaller than the
// function is at fault, as for an entry point with the wrong signature.
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

// Checker holds the program, the findings, and the tables of the one function being checked. The
// last three fields are where a violation found below is reported: an instruction check names no
// place of its own, so the walk sets the place before it runs the check.
@(private)
Checker :: struct {
	program:  Program_IR,
	found:    [dynamic]Violation,
	body:     Func,
	preds:    [][dynamic]Block_ID, // the predecessor edges of each block, duplicates included
	home:     []Block_ID, // the block each value is defined in, NO_BLOCK when it is in none
	index:    []i32, // the place of each value inside its block
	idom:     []Block_ID, // the immediate dominator of each block, NO_BLOCK when unreachable
	order:    []i32, // the place of each block in reverse post-order, -1 when unreachable
	func:     Func_ID,
	block:    Block_ID,
	position: i32,
	value:    Value_ID,
}

@(private)
verify_func :: proc(c: ^Checker, id: Func_ID) {
	c.func = id
	c.body = c.program.funcs[id]
	c.block = NO_BLOCK
	c.value = NO_VALUE

	blocks := len(c.body.blocks)
	values := len(c.body.values)
	if blocks == 0 {
		// declare_func reserved the row and nothing ever filled it: there is no entry block to
		// enter and nothing below has anything to walk.
		report(c, .Missing_Body)
		return
	}
	c.preds = make([][dynamic]Block_ID, blocks, context.temp_allocator)
	for &list in c.preds {
		list = make([dynamic]Block_ID, context.temp_allocator)
	}
	c.home = make([]Block_ID, values, context.temp_allocator)
	c.index = make([]i32, values, context.temp_allocator)
	c.idom = make([]Block_ID, blocks, context.temp_allocator)
	c.order = make([]i32, blocks, context.temp_allocator)

	locate_values(c)
	verify_blocks(c)
	build_dominators(c)

	for block in 0 ..< blocks {
		c.block = Block_ID(block)
		for value, position in c.body.blocks[block].instructions {
			if int(value) >= values {
				continue // locate_values reported it; there is no instruction to check
			}
			c.position = i32(position)
			c.value = value
			verify_instruction(c)
		}
	}
}

// locate_values records where each value is defined, which is what the dominance questions below
// are asked about.
@(private)
locate_values :: proc(c: ^Checker) {
	for &block in c.home {
		block = NO_BLOCK
	}
	for block, index in c.body.blocks {
		c.block = Block_ID(index)
		for value, position in block.instructions {
			if int(value) >= len(c.body.values) {
				c.value = value
				report(c, .Unknown_Value)
				continue
			}
			c.home[value] = Block_ID(index)
			c.index[value] = i32(position)
		}
	}
}

// verify_blocks checks the shape of every block and collects the edges between them.
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
			continue
		}
		add_edges(c, Block_ID(index), c.body.values[last].variant)
	}
}

@(private)
add_edges :: proc(c: ^Checker, block: Block_ID, variant: Variant) {
	#partial switch v in variant {
	case Jump:
		if int(v.target) < len(c.body.blocks) {
			append(&c.preds[v.target], block)
		}
	case Branch:
		if int(v.then_block) < len(c.body.blocks) {
			append(&c.preds[v.then_block], block)
		}
		if int(v.else_block) < len(c.body.blocks) {
			append(&c.preds[v.else_block], block)
		}
	}
}

// build_dominators numbers the blocks the entry reaches in reverse post-order and fills idom with
// the iterative dominator algorithm: every block takes the common dominator of the predecessors
// already numbered, until nothing moves.
@(private)
build_dominators :: proc(c: ^Checker) {
	for &position in c.order {
		position = -1
	}
	for &block in c.idom {
		block = NO_BLOCK
	}
	if len(c.body.blocks) == 0 {
		return
	}

	post := walk_post_order(c)
	for i in 0 ..< len(post) {
		c.order[post[len(post) - 1 - i]] = i32(i)
	}

	c.idom[ENTRY] = ENTRY
	changed := true
	for changed {
		changed = false
		// Reverse post-order without the entry, whose dominator is itself.
		for i in 1 ..< len(post) {
			block := post[len(post) - 1 - i]
			found := NO_BLOCK
			for pred in c.preds[block] {
				if c.idom[pred] == NO_BLOCK {
					continue
				}
				found = pred if found == NO_BLOCK else common_dominator(c, pred, found)
			}
			if found != NO_BLOCK && c.idom[block] != found {
				c.idom[block] = found
				changed = true
			}
		}
	}
}

// walk_post_order lists the blocks the entry reaches, each after its successors. The walk carries
// its own stack: a function of many blocks must not grow the machine stack.
@(private)
walk_post_order :: proc(c: ^Checker) -> [dynamic]Block_ID {
	Frame :: struct {
		block: Block_ID,
		next:  int, // the successor to follow when this frame comes up again
	}

	count := len(c.body.blocks)
	post := make([dynamic]Block_ID, 0, count, context.temp_allocator)
	visited := make([]bool, count, context.temp_allocator)
	stack := make([dynamic]Frame, 0, count, context.temp_allocator)

	visited[ENTRY] = true
	append(&stack, Frame{block = ENTRY})
	for len(stack) > 0 {
		frame := &stack[len(stack) - 1]
		target, more := successor(c, frame.block, frame.next)
		if !more {
			append(&post, frame.block)
			pop(&stack)
			continue
		}
		frame.next += 1
		if int(target) >= count || visited[target] {
			continue
		}
		visited[target] = true
		append(&stack, Frame{block = target})
	}
	return post
}

// successor answers the i-th block the terminator of block jumps to. A target outside the function
// is answered as it stands: the caller skips it, and the instruction check reports it.
@(private)
successor :: proc(c: ^Checker, block: Block_ID, i: int) -> (target: Block_ID, more: bool) {
	instructions := c.body.blocks[block].instructions
	if len(instructions) == 0 {
		return
	}
	last := instructions[len(instructions) - 1]
	if int(last) >= len(c.body.values) {
		return
	}
	#partial switch v in c.body.values[last].variant {
	case Jump:
		if i == 0 {
			return v.target, true
		}
	case Branch:
		switch i {
		case 0:
			return v.then_block, true
		case 1:
			return v.else_block, true
		}
	}
	return
}

// common_dominator walks two blocks up their dominator chains until they meet, comparing them by
// reverse post-order number: the block further from the entry moves first.
@(private)
common_dominator :: proc(c: ^Checker, left, right: Block_ID) -> Block_ID {
	left, right := left, right
	for left != right {
		for c.order[left] > c.order[right] {
			left = c.idom[left]
		}
		for c.order[right] > c.order[left] {
			right = c.idom[right]
		}
	}
	return left
}

// dominates says whether every path from the entry to `block` goes through `head`.
@(private)
dominates :: proc(c: ^Checker, head, block: Block_ID) -> bool {
	if c.order[head] < 0 || c.order[block] < 0 {
		return false
	}
	walk := block
	for {
		if walk == head {
			return true
		}
		if walk == ENTRY {
			return false
		}
		next := c.idom[walk]
		if next == NO_BLOCK || next == walk {
			return false
		}
		walk = next
	}
}

// verify_instruction checks one instruction against the closed set. It is the same exhaustive
// switch codegen is: a variant added to the union without a case here fails the build.
@(private)
verify_instruction :: proc(c: ^Checker) {
	instruction := c.body.values[c.value]
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
		expect_result(c, F64)

	case Const_Bool:
		expect_result(c, BOOL)

	case Const_Undefined, Const_Null:
		expect_result(c, TAGGED)

	case Const_String:
		if int(v.text) >= len(c.program.strings) {
			report(c, .Unknown_Id)
		}
		expect_result(c, STR)

	case Binary:
		expect_operand(c, v.left, F64)
		expect_operand(c, v.right, F64)
		expect_result(c, F64)

	case Unary:
		want := BOOL if v.op == .Not else F64
		expect_operand(c, v.operand, want)
		expect_result(c, want)

	case Compare:
		left, left_known := operand(c, v.left)
		right, right_known := operand(c, v.right)
		if left_known && right_known {
			ordered := v.op != .Equal && v.op != .Not_Equal
			if left != right || !comparable(left) || (ordered && left != F64) {
				report(c, .Operand_Type)
			}
		}
		expect_result(c, BOOL)

	case Phi:
		if instruction.type == VOID {
			report(c, .Result_Type)
		}
		if c.order[c.block] >= 0 && !edges_match(c, v.incoming) {
			report(c, .Phi_Edges)
		}
		for edge in v.incoming {
			verify_edge(c, edge, instruction.type)
		}

	case Alloc:
		table, known := layout_of(c, v.layout)
		if !known {
			report(c, .Unknown_Id)
			return
		}
		if table.kind != .Object && table.kind != .Environment {
			report(c, .Operand_Type)
		}
		expect_result(c, ref(v.layout))

	case Field_Load:
		field, known := field_of(c, v.cell, v.field)
		if known && !slot_fits(field.kind, instruction.type) {
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

	case Bounds_Check:
		array_element(c, v.array) // for the check alone: the element kind is nothing to this one
		expect_operand(c, v.index, F64)
		expect_site(c, v.not_integer)
		expect_site(c, v.out_of_range)
		expect_result(c, F64)

	case Element_Load:
		element, known := array_element(c, v.array)
		expect_checked_index(c, v.index)
		if known && !slot_fits(element, instruction.type) {
			report(c, .Result_Type)
		}

	case Element_Store:
		element, known := array_element(c, v.array)
		expect_checked_index(c, v.index)
		if known {
			if traced(element) {
				report(c, .Store_Kind)
			}
			expect_slot(c, v.value, element)
		}
		expect_result(c, VOID)

	case Element_Store_Ref:
		element, known := array_element(c, v.array)
		expect_checked_index(c, v.index)
		if known {
			if !traced(element) {
				report(c, .Store_Kind)
			}
			expect_slot(c, v.value, element)
		}
		expect_result(c, VOID)

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
		if instruction.type == VOID || instruction.type == TAGGED {
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

	case Call:
		if int(v.func) >= len(c.program.funcs) {
			report(c, .Unknown_Id)
			return
		}
		callee := c.program.funcs[v.func]
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
		for arg in v.args {
			// A function value carries no signature, so only the arguments themselves are checked.
			operand(c, arg)
		}

	case Call_Runtime:
		exports := abi.RUNTIME_EXPORTS
		export := exports[v.export]
		if len(v.args) != len(export.params) {
			report(c, .Argument_Count)
		}
		for arg, i in v.args {
			type, known := operand(c, arg)
			if known && i < len(export.params) && export.params[i] == .Ptr && !is_reference(type) {
				report(c, .Operand_Type)
			}
		}
		if export.result == .Void {
			expect_result(c, VOID)
		} else if !is_reference(instruction.type) {
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

// verify_edge checks one edge of a phi. The value has to be there at the end of the block the edge
// names, which is the block control came through, rather than before the phi itself.
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
	if c.order[edge.block] >= 0 && !reaches_end(c, edge.block, edge.value) {
		report(c, .Use_Before_Definition)
	}
	if c.body.values[edge.value].type != want {
		report(c, .Operand_Type)
	}
}

// edges_match says whether a phi has exactly one edge per predecessor edge of its block, so a
// branch that names one block on both sides gets two.
@(private)
edges_match :: proc(c: ^Checker, incoming: []Incoming) -> bool {
	preds := c.preds[c.block]
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
	if c.order[c.block] >= 0 && !reaches(c, id) {
		report(c, .Use_Before_Definition)
	}
	return c.body.values[id].type, true
}

@(private)
expect_operand :: proc(c: ^Checker, id: Value_ID, want: Type) {
	type, known := operand(c, id)
	if known && type != want {
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

// expect_checked_index requires the index of an element access to be the answer of a bounds check,
// so the check cannot drift away from the access it guards.
@(private)
expect_checked_index :: proc(c: ^Checker, id: Value_ID) {
	type, known := operand(c, id)
	if !known {
		return
	}
	if type != F64 {
		report(c, .Operand_Type)
	}
	if _, checked := c.body.values[id].variant.(Bounds_Check); !checked {
		report(c, .Unchecked_Index)
	}
}

@(private)
expect_result :: proc(c: ^Checker, want: Type) {
	if c.body.values[c.value].type != want {
		report(c, .Result_Type)
	}
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

// reaches says whether the definition of a value is in hand where the instruction being checked
// stands: earlier in the same block, or in a block that dominates this one.
@(private)
reaches :: proc(c: ^Checker, id: Value_ID) -> bool {
	home := c.home[id]
	if home == NO_BLOCK {
		return false
	}
	if home == c.block {
		return c.index[id] < c.position
	}
	return dominates(c, home, c.block)
}

// reaches_end says whether the definition of a value is in hand at the end of a block, which is
// what an edge of a phi asks.
@(private)
reaches_end :: proc(c: ^Checker, block: Block_ID, id: Value_ID) -> bool {
	home := c.home[id]
	if home == NO_BLOCK {
		return false
	}
	return home == block || dominates(c, home, block)
}

@(private)
field_of :: proc(c: ^Checker, cell: Value_ID, index: i32) -> (field: abi.Field, known: bool) {
	type, cell_known := operand(c, cell)
	if !cell_known {
		return
	}
	if type.kind != .Ref {
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
	if type.kind != .Ref {
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

// slot_fits says whether a value of this type can be written into a slot of this kind. A Ref slot
// takes a reference to any layout: abi.Field carries a slot kind and not a table of its own, so the
// layout behind a traced slot is not knowable here.
@(private)
slot_fits :: proc(kind: abi.Slot_Kind, type: Type) -> bool {
	switch kind {
	case .Number:
		return type == F64
	case .Boolean:
		return type == BOOL
	case .Ref:
		return type.kind == .Ref
	case .Tagged:
		return type == TAGGED
	}
	return false
}

// traced says whether the collector follows what a slot of this kind holds, which is what decides
// between a plain store and a store that ends in _Ref.
@(private)
traced :: proc(kind: abi.Slot_Kind) -> bool {
	return kind == .Ref || kind == .Tagged
}

// is_reference says whether a value of this type is the one pointer a runtime export takes.
@(private)
is_reference :: proc(type: Type) -> bool {
	return type.kind == .Str || type.kind == .Ref || type.kind == .Closure
}

// comparable says whether Equal and Not_Equal compare two values of this type themselves. A string
// and a tagged value go through the runtime instead: one holds its contents, the other its tag.
@(private)
comparable :: proc(type: Type) -> bool {
	return type == F64 || type == BOOL || type.kind == .Ref || type == CLOSURE
}

@(private)
boxable :: proc(type: Type) -> bool {
	return type == F64 || type == BOOL || type == STR || type.kind == .Ref || type == CLOSURE
}

@(private)
report :: proc(c: ^Checker, kind: Violation_Kind) {
	append(&c.found, Violation{kind = kind, func = c.func, block = c.block, value = c.value})
}
