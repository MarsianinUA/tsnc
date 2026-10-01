#+private
package opt

import "base:runtime"

import "../ir"

/*
Integer narrowing: a number whose range is integral, never -0 and inside ±2^53 becomes an I32 when
the range fits 32 bits and an I64 otherwise.

An instruction that computes the number is retyped in place: a constant, arithmetic, a negation, a
phi, a length, a unit, a check's answer, and the bitwise operators, which answer I32 (an unsigned
shift I64) whatever they read. Arithmetic, a phi and a comparison take the widest type among their
own and their operands', so a type only ever grows, from I32 to I64, and a conversion is a widening
or a crossing to or from F64, never a truncation. A number that arrives as F64 and must stay one,
a parameter, a load, a call's result, is converted once, right after its definition, for the uses
that want an integer.

A conversion out of F64 runs wherever the definition runs, so it is only made of a value whose own
range, not one a comparison narrowed at the use, is integral. An arithmetic operation or a phi that
would need any other conversion stays F64.
*/

narrow :: proc(p: ^ir.Program_IR, ranges: Ranges, allocator: runtime.Allocator) {
	for id in 0 ..< len(p.funcs) {
		narrow_func(&p.funcs[id], ranges.funcs[id], allocator)
	}
}

@(private = "file")
Narrowing :: struct {
	func:      ^ir.Func,
	fr:        Func_Ranges,
	home:      []ir.Block_ID, // by Value_ID
	types:     []ir.Type, // by Value_ID: the type it ends up with
	compared:  []ir.Type, // by Value_ID of a Compare: what both operands are read as
	editor:    Editor,
	converted: map[Conversion]ir.Value_ID, // only ever read by key
}

@(private = "file")
Conversion :: struct {
	value: ir.Value_ID,
	type:  ir.Type_Kind,
}

// Use is one number operand, by its place in ir.operands, and the type its instruction reads it
// as.
@(private = "file")
Use :: struct {
	consumer: ir.Value_ID,
	field:    int,
	value:    ir.Value_ID,
	want:     ir.Type,
	dead:     bool, // the edge of a phi out of a block nothing reaches
}

@(private = "file")
narrow_func :: proc(func: ^ir.Func, fr: Func_Ranges, allocator: runtime.Allocator) {
	count := len(func.values)
	n := Narrowing {
		func     = func,
		fr       = fr,
		home     = home_blocks(func^),
		types    = make([]ir.Type, count, context.temp_allocator),
		compared = make([]ir.Type, count, context.temp_allocator),
	}
	if !choose_types(&n) {
		return
	}

	uses := list_uses(&n)
	settle_constants(&n, uses)

	n.editor = begin_edit(func, allocator)
	n.converted = make(map[Conversion]ir.Value_ID, context.temp_allocator)
	fields := make([dynamic]^ir.Value_ID, context.temp_allocator)
	for use in uses {
		if use.want == n.types[use.value] {
			continue
		}
		replaced := replacement(&n, use)
		// Only now: inserting it may have moved the instructions the pointers point into.
		ir.operands(&n.editor.values[use.consumer].variant, &fields)
		fields[use.field]^ = replaced
	}
	for type, id in n.types {
		n.editor.values[id].type = type
	}
	end_edit(&n.editor)
}

// choose_types answers whether any number became an integer.
@(private = "file")
choose_types :: proc(n: ^Narrowing) -> bool {
	values := n.func.values
	narrowed := false
	for instruction, id in values {
		n.types[id] = instruction.type
		r := n.fr.values[id]
		if instruction.type != ir.F64 || r.kind != .Integral || r.negative_zero {
			continue
		}
		type := range_type(r)
		#partial switch v in instruction.variant {
		case ir.Const_Number, ir.Phi:
		case ir.Binary:
			#partial switch v.op {
			case .Shift_Left, .Shift_Right, .Bit_And, .Bit_Or, .Bit_Xor:
				type = ir.I32
			case .Shift_Right_Unsigned:
				type = ir.I64
			case .Divide, .Power:
				continue
			}
		case ir.Unary:
			type = ir.I32 if v.op == .Bit_Not else type
		case ir.Length:
			type = ir.I64
		case ir.Unit_Load:
			type = ir.I32
		case:
			continue
		}
		n.types[id] = type
		narrowed = true
	}
	if !narrowed {
		return false
	}

	// Types only grow, and an operation whose operand cannot be converted falls back to F64 for
	// good, so this stops.
	for changed := true; changed; {
		changed = false
		for instruction, id in values {
			before := n.types[id]
			#partial switch v in instruction.variant {
			case ir.Binary:
				if arithmetic(v.op) && ir.is_integer(before) {
					n.types[id] = widest(n, before, {v.left, v.right})
				}
			case ir.Unary:
				if v.op == .Negate && ir.is_integer(before) {
					n.types[id] = widest(n, before, {v.operand})
				}
			case ir.Phi:
				if ir.is_integer(before) {
					n.types[id] = widest_edge(n, before, v.incoming)
				}
			case ir.Bounds_Check:
				n.types[id] = n.types[v.index]
			case ir.Proved_Index:
				n.types[id] = n.types[v.index]
			}
			changed ||= n.types[id] != before
		}
	}

	for instruction, id in values {
		compare, is_compare := instruction.variant.(ir.Compare)
		if !is_compare || !ir.is_number(n.types[compare.left]) {
			continue
		}
		n.compared[id] = ir.F64
		if ir.is_integer(n.types[compare.left]) || ir.is_integer(n.types[compare.right]) {
			n.compared[id] = widest(n, ir.I32, {compare.left, compare.right})
		}
	}
	return true
}

@(private = "file")
arithmetic :: proc(op: ir.Binary_Op) -> bool {
	return op == .Add || op == .Subtract || op == .Multiply || op == .Remainder
}

@(private = "file")
range_type :: proc(r: Range) -> ir.Type {
	return ir.I32 if r.lo >= INT32.lo && r.hi <= INT32.hi else ir.I64
}

// widest answers the type an operation reads all of its operands as, or F64 when one of them
// cannot become an integer.
@(private = "file")
widest :: proc(n: ^Narrowing, type: ir.Type, operands: []ir.Value_ID) -> ir.Type {
	type := type
	for operand in operands {
		need, ok := integer_of(n, operand)
		if !ok {
			return ir.F64
		}
		if need == ir.I64 {
			type = ir.I64
		}
	}
	return type
}

// widest_edge leaves out an edge out of a block nothing reaches: it never runs, and a zero of the
// phi's type stands in for whatever it carries.
@(private = "file")
widest_edge :: proc(n: ^Narrowing, type: ir.Type, incoming: []ir.Incoming) -> ir.Type {
	type := type
	for edge in incoming {
		if n.fr.flow.rank[edge.block] < 0 {
			continue
		}
		type = widest(n, type, {edge.value})
		if type == ir.F64 {
			return type
		}
	}
	return type
}

// integer_of answers the integer type a narrowed operation reads an operand as: its own, or for an
// F64 the type its range needs, when that range is integral. A value in a block nothing reaches
// converts to anything, since the conversion never runs.
@(private = "file")
integer_of :: proc(n: ^Narrowing, value: ir.Value_ID) -> (ir.Type, bool) {
	type := n.types[value]
	if ir.is_integer(type) {
		return type, true
	}
	if n.home[value] == ir.NO_BLOCK || n.fr.flow.rank[n.home[value]] < 0 {
		return ir.I32, true
	}
	r := n.fr.values[value]
	if r.kind != .Integral {
		return {}, false
	}
	return range_type(r), true
}

// list_uses lists every number operand with the type its instruction reads it as: F64 unless the
// instruction was narrowed. A bitwise operator and an index read any number type as it is.
@(private = "file")
list_uses :: proc(n: ^Narrowing) -> []Use {
	uses := make([dynamic]Use, context.temp_allocator)
	fields := make([dynamic]^ir.Value_ID, context.temp_allocator)
	for &instruction, id in n.func.values {
		consumer := ir.Value_ID(id)
		ir.operands(&instruction.variant, &fields)
		for field, i in fields {
			value := field^
			if !ir.is_number(n.types[value]) {
				continue
			}
			use := Use {
				consumer = consumer,
				field    = i,
				value    = value,
				want     = ir.F64,
			}
			#partial switch &v in instruction.variant {
			case ir.Binary:
				if arithmetic(v.op) {
					use.want = n.types[consumer]
				} else if v.op != .Divide && v.op != .Power {
					use.want = n.types[value]
				}
			case ir.Unary:
				use.want = n.types[consumer] if v.op == .Negate else n.types[value]
			case ir.Compare:
				use.want = n.compared[consumer]
			case ir.Phi:
				use.want = n.types[consumer]
				use.dead = n.fr.flow.rank[v.incoming[i].block] < 0
			case ir.Bounds_Check, ir.Proved_Index, ir.Element_Load, ir.Unit_Load, ir.Ascii_Cell:
				use.want = n.types[value]
			case ir.Element_Store:
				if field == &v.index {
					use.want = n.types[value]
				}
			case ir.Element_Store_Ref:
				use.want = n.types[value]
			}
			append(&uses, use)
		}
	}
	return uses[:]
}

// settle_constants gives an integer constant the type its readers want, so that no twin of another
// type stands beside it unread: I32 when one reads it so, which its range then fits, else I64, and
// its F64 back when no reader wants an integer.
@(private = "file")
settle_constants :: proc(n: ^Narrowing, uses: []Use) {
	wants := make([]bit_set[ir.Type_Kind], len(n.types), context.temp_allocator)
	for use in uses {
		if ir.is_integer(use.want) && !use.dead {
			wants[use.value] += {use.want.kind}
		}
	}
	for instruction, id in n.func.values {
		_, is_constant := instruction.variant.(ir.Const_Number)
		if !is_constant || !ir.is_integer(n.types[id]) {
			continue
		}
		switch {
		case .I32 in wants[id]:
			n.types[id] = ir.I32
		case .I64 in wants[id]:
			n.types[id] = ir.I64
		case:
			n.types[id] = instruction.type
		}
	}
}

// replacement answers the value a use reads in place of its operand: a constant of the wanted type
// or a conversion, one per value and type, right after the definition, so it dominates every use
// the definition does.
@(private = "file")
replacement :: proc(n: ^Narrowing, use: Use) -> ir.Value_ID {
	value := use.value
	source := n.func.values[value]
	if use.dead {
		// A value for an edge that never runs, which ir.verify does not hold to dominance.
		zero := ir.Instruction {
			span    = source.span,
			type    = use.want,
			variant = ir.Const_Number{},
		}
		return insert_after(&n.editor, after_phis(n, use.consumer), zero)
	}
	key := Conversion{value, use.want.kind}
	if found, known := n.converted[key]; known {
		return found
	}
	from := n.types[value]
	ensure(from != ir.I64 || use.want != ir.I32, "a conversion that truncates")
	instruction := ir.Instruction {
		span = source.span,
		type = use.want,
	}
	if constant, is_constant := source.variant.(ir.Const_Number); is_constant {
		// An integer constant is never -0, and this one is an integer wherever an integer wants it.
		instruction.variant = ir.Const_Number {
			value = constant.value + 0,
		}
	} else {
		_, integral := integer_of(n, value)
		ensure(from != ir.F64 || integral, "a conversion of a value that is no integer")
		instruction.variant = ir.Convert {
			value = value,
		}
	}
	anchor := value
	#partial switch _ in source.variant {
	case ir.Param:
		anchor = last_param(n)
	case ir.Phi:
		anchor = after_phis(n, value)
	}
	id := insert_after(&n.editor, anchor, instruction)
	n.converted[key] = id
	return id
}

// after_phis answers the last phi of the block that holds `value`, which a new instruction of that
// block has to follow.
@(private = "file")
after_phis :: proc(n: ^Narrowing, value: ir.Value_ID) -> ir.Value_ID {
	last := ir.NO_VALUE
	for id in n.func.blocks[n.home[value]].instructions {
		if _, is_phi := n.func.values[id].variant.(ir.Phi); !is_phi {
			break
		}
		last = id
	}
	return last
}

@(private = "file")
last_param :: proc(n: ^Narrowing) -> ir.Value_ID {
	last := ir.NO_VALUE
	for id in n.func.blocks[ir.ENTRY].instructions {
		if _, is_param := n.func.values[id].variant.(ir.Param); is_param {
			last = id
		}
	}
	return last
}
