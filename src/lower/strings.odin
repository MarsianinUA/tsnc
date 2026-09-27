package lower

import "../abi"
import "../ast"
import "../ir"
import "../source"

/*
Strings. A string is a reference to an immutable cell (requirements 3.2), and everything that reads
or builds one is a runtime row of abi, apart from its length and its units, which are loads, and a
one-unit string below ir.ASCII_LIMIT, which is a row of a static table (string_piece).

`+` with a string on either side, a template and String(x) turn each operand into a string first,
the way ECMAScript's ToString does: a number through the runtime's own shortest decimal, and a
boolean, an object, an array or a tagged value through Value_To_String, which answers the words
Node answers. `+` asks ToPrimitive first, and so an object's own valueOf, which Node would call:
Value_To_Primitive_String refuses such an object where Value_To_String would not. A function is
refused by both; check reports one whose type says it is a function (T2028).
*/

// to_string answers the string ToString makes of a value; a string is its own. primitive asks for
// ToString(ToPrimitive(value)) instead, what `+` joins, which differs only where the value may be
// an object.
@(private)
to_string :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	span: source.Span,
	primitive := false,
) -> ir.Value_ID {
	if value == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	export := abi.Runtime_Proc.Value_To_String
	switch value_type(s, value).kind {
	case .Str:
		return value
	case .F64:
		call := ir.Call_Runtime {
			export = .Number_To_String,
			args   = {value},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	case .Ref, .Tagged:
		if primitive {
			export = .Value_To_Primitive_String
		}
		fallthrough
	case .Bool, .Closure:
		call := ir.Call_Runtime {
			export = export,
			args   = {coerce(s, value, ir.TAGGED, span)},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	case .Void:
	}
	return ir.NO_VALUE
}

@(private)
lower_concat :: proc(s: ^Func_State, left, right: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	first := to_string(s, left, span, primitive = true)
	second := to_string(s, right, span, primitive = true)
	if first == ir.NO_VALUE || second == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	return concat(s, first, second, span)
}

@(private)
concat :: proc(s: ^Func_State, left, right: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	call := ir.Call_Runtime {
		export = .String_Concat,
		args   = {left, right},
	}
	return ir.emit(&s.fb, ir.STR, call, span)
}

// lower_template joins the cooked parts with the substitutions between them, left to right; an
// empty part adds nothing, so it is left out.
@(private)
lower_template :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Template) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	text := ir.NO_VALUE
	if len(node.parts[0]) > 0 {
		text = string_constant(s, node.parts[0], span)
	}
	complete := true
	for expression, i in node.expressions {
		piece := to_string(s, lower_expression(s, expression), s.tree.nodes[expression].span)
		if piece == ir.NO_VALUE {
			complete = false
			continue
		}
		text = piece if text == ir.NO_VALUE else concat(s, text, piece, span)
		if part := node.parts[i + 1]; len(part) > 0 {
			text = concat(s, text, string_constant(s, part, span), span)
		}
	}
	if !complete {
		return ir.NO_VALUE
	}
	return text if text != ir.NO_VALUE else string_constant(s, "", span)
}

@(private)
string_constant :: proc(s: ^Func_State, text: string, span: source.Span) -> ir.Value_ID {
	id := ir.intern_string(&s.low.builder, text)
	return ir.emit(&s.fb, ir.STR, ir.Const_String{text = id}, span)
}

// compare_strings orders by the runtime's `<`: `a > b` is `b < a`, and `<=` and `>=` are the
// negation of the strict order the other way round.
@(private)
compare_strings :: proc(
	s: ^Func_State,
	op: ir.Compare_Op,
	left, right: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	a, b := left, right
	negate := false
	switch op {
	case .Equal:
		return strings_equal(s, left, right, span)
	case .Not_Equal:
		return negated(s, strings_equal(s, left, right, span), span)
	case .Less:
	case .Greater:
		a, b = right, left
	case .Less_Equal:
		a, b, negate = right, left, true
	case .Greater_Equal:
		negate = true
	}
	call := ir.Call_Runtime {
		export = .String_Less,
		args   = {a, b},
	}
	answer := ir.emit(&s.fb, ir.BOOL, call, span)
	if negate {
		answer = negated(s, answer, span)
	}
	return answer
}

// strings_equal is `===`. A literal of at most one unit on either side is a length and a unit;
// anything else reaches the runtime only past the identity and length tests.
@(private)
strings_equal :: proc(s: ^Func_State, left, right: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	if units, short := short_literal(s, right); short {
		return equals_literal(s, left, units, span)
	}
	if units, short := short_literal(s, left); short {
		return equals_literal(s, right, units, span)
	}
	yes := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
	no := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
	same := ir.emit(&s.fb, ir.BOOL, ir.Same_Cell{a = left, b = right}, span)

	lengths := ir.add_block(&s.fb)
	contents := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	one_cell := here(s)
	first := ir.Branch {
		condition  = same,
		then_block = join,
		else_block = lengths,
	}
	ir.emit(&s.fb, ir.VOID, first, span)

	ir.use_block(&s.fb, lengths)
	left_length := ir.emit(&s.fb, ir.F64, ir.Length{value = left}, span)
	right_length := ir.emit(&s.fb, ir.F64, ir.Length{value = right}, span)
	compare := ir.Compare {
		op    = .Equal,
		left  = left_length,
		right = right_length,
	}
	equal_lengths := ir.emit(&s.fb, ir.BOOL, compare, span)
	other_lengths := here(s)
	second := ir.Branch {
		condition  = equal_lengths,
		then_block = contents,
		else_block = join,
	}
	ir.emit(&s.fb, ir.VOID, second, span)

	ir.use_block(&s.fb, contents)
	call := ir.Call_Runtime {
		export = .String_Equal,
		args   = {left, right},
	}
	answer := ir.emit(&s.fb, ir.BOOL, call, span)
	compared := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	edges := []Edge{one_cell, other_lengths, compared}
	return join_values(s, join, edges, {yes, no, answer}, ir.BOOL, span)
}

// short_literal reads the value, not its type: a literal type may hold another string that came
// through `any`.
@(private)
short_literal :: proc(s: ^Func_State, value: ir.Value_ID) -> (units: []u16, short: bool) {
	constant, is_constant := s.fb.values[value].variant.(ir.Const_String)
	if !is_constant {
		return nil, false
	}
	units = s.low.builder.string_pool[constant.text]
	return units, len(units) <= 1
}

@(private)
equals_literal :: proc(
	s: ^Func_State,
	text: ir.Value_ID,
	units: []u16,
	span: source.Span,
) -> ir.Value_ID {
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = text}, span)
	want := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = f64(len(units))}, span)
	fits := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Equal, left = length, right = want}, span)
	if len(units) == 0 {
		return fits
	}
	no := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)

	unit_test := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	other_length := here(s)
	branch := ir.Branch {
		condition  = fits,
		then_block = unit_test,
		else_block = join,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, unit_test)
	zero := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	// It cannot fail after the length test, and it is what Unit_Load reads through.
	checked := bounds_check(s, text, zero, span)
	unit := ir.emit(&s.fb, ir.F64, ir.Unit_Load{text = text, index = checked}, span)
	expected := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = f64(units[0])}, span)
	same := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Equal, left = unit, right = expected}, span)
	one_unit := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	return join_values(s, join, {other_length, one_unit}, {no, same}, ir.BOOL, span)
}

// string_piece is what a read at a checked index answers: a static cell for a unit below
// ir.ASCII_LIMIT, the answer of the export for anything else.
@(private)
string_piece :: proc(
	s: ^Func_State,
	text, checked: ir.Value_ID,
	export: abi.Runtime_Proc,
	span: source.Span,
) -> ir.Value_ID {
	unit := ir.emit(&s.fb, ir.F64, ir.Unit_Load{text = text, index = checked}, span)
	limit := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = ir.ASCII_LIMIT}, span)
	ascii := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Less, left = unit, right = limit}, span)

	static := ir.add_block(&s.fb)
	other := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	branch := ir.Branch {
		condition  = ascii,
		then_block = static,
		else_block = other,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, static)
	cell := ir.emit(&s.fb, ir.STR, ir.Ascii_Cell{unit = unit}, span)
	from_table := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	ir.use_block(&s.fb, other)
	call := ir.Call_Runtime {
		export = export,
		args   = {text, checked},
	}
	made := ir.emit(&s.fb, ir.STR, call, span)
	from_runtime := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	return join_values(s, join, {from_table, from_runtime}, {cell, made}, ir.STR, span)
}

// lower_string_of is String(x), which answers the empty string for no argument at all.
@(private)
lower_string_of :: proc(s: ^Func_State, node: ast.Call, span: source.Span) -> ir.Value_ID {
	if len(node.args) == 0 {
		return string_constant(s, "", span)
	}
	return to_string(s, lower_expression(s, node.args[0]), span)
}

// lower_string_includes is `indexOf(search, position) !== -1`, which is includes in every corner,
// an empty search past the end included.
@(private)
lower_string_includes :: proc(
	s: ^Func_State,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if len(node.args) == 0 {
		return ir.NO_VALUE
	}
	search := runtime_argument(s, node.args[0], .Ptr)
	position: ir.Value_ID
	if len(node.args) > 1 {
		position = optional_argument(s, node.args[1], 0, span)
	} else {
		position = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	}
	if search == ir.NO_VALUE || position == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	find := ir.Call_Runtime {
		export = .String_Index_Of,
		args   = {receiver, search, position},
	}
	index := ir.emit(&s.fb, ir.F64, find, span)
	missing := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = -1}, span)
	return ir.emit(
		&s.fb,
		ir.BOOL,
		ir.Compare{op = .Not_Equal, left = index, right = missing},
		span,
	)
}
