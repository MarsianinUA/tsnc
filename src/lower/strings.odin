package lower

import "../abi"
import "../ast"
import "../ir"
import "../source"

/*
Strings. A string is a reference to an immutable cell (requirements 3.2), and everything that reads
or builds one is a runtime row of abi, apart from its length, which is one load.

`+` with a string on either side, a template and String(x) turn each operand into a string first,
the way ECMAScript's ToString does: a number through the runtime's own shortest decimal, and a
boolean, an object or an array through Value_To_String, which answers the words Node answers. A
tagged operand needs the tag check of T5.9 first.
*/

// to_string answers the string ToString makes of a value; a string is its own.
@(private)
to_string :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	if value == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	switch value_type(s, value).kind {
	case .Str:
		return value
	case .F64:
		call := ir.Call_Runtime {
			export = .Number_To_String,
			args   = {value},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	case .Bool, .Ref, .Closure:
		boxed := ir.emit(&s.fb, ir.TAGGED, ir.Box{value = value}, span)
		call := ir.Call_Runtime {
			export = .Value_To_String,
			args   = {boxed},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	case .Tagged:
		return later(s, span, "narrowing a union")
	case .Void:
	}
	return ir.NO_VALUE
}

@(private)
lower_concat :: proc(s: ^Func_State, left, right: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	first := to_string(s, left, span)
	second := to_string(s, right, span)
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

// compare_strings goes by the runtime's `===` and `<`: `a > b` is `b < a`, and `<=` and `>=` are
// the negation of the strict order the other way round.
@(private)
compare_strings :: proc(
	s: ^Func_State,
	op: ir.Compare_Op,
	left, right: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	export := abi.Runtime_Proc.String_Less
	a, b := left, right
	negate := false
	switch op {
	case .Equal:
		export = .String_Equal
	case .Not_Equal:
		export, negate = .String_Equal, true
	case .Less:
	case .Greater:
		a, b = right, left
	case .Less_Equal:
		a, b, negate = right, left, true
	case .Greater_Equal:
		negate = true
	}
	call := ir.Call_Runtime {
		export = export,
		args   = {a, b},
	}
	answer := ir.emit(&s.fb, ir.BOOL, call, span)
	if negate {
		answer = ir.emit(&s.fb, ir.BOOL, ir.Unary{op = .Not, operand = answer}, span)
	}
	return answer
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
		position = runtime_argument(s, node.args[1], .Number)
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
