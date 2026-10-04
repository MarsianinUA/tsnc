package lower

import "core:slice"

import "../abi"
import "../ast"
import "../bind"
import "../check"
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
	type := value_type(s, value)
	switch type.kind {
	case .Str:
		// One that may be null goes to the runtime, which makes "null" or "undefined" of it.
		if type.nullish == .None {
			return value
		}
	case .F64:
		call := ir.Call_Runtime {
			export = .Number_To_String,
			args   = {value},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	case .Ref, .Any_Ref, .Tagged:
		if primitive {
			export = .Value_To_Primitive_String
		}
	case .Bool, .Closure:
	case .Void:
		return ir.NO_VALUE
	case .I32, .I64:
		unreachable()
	}
	call := ir.Call_Runtime {
		export = export,
		args   = {coerce(s, value, ir.TAGGED, span)},
	}
	return ir.emit(&s.fb, ir.STR, call, span)
}

// lower_concat is a `+=` to a target not typed string, such as `any` or a union, that meets one.
@(private)
lower_concat :: proc(s: ^Func_State, left, right: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	first := piece(s, left, span, primitive = true)
	second := piece(s, right, span, primitive = true)
	return emit_join(s, {first, second}, span)
}

@(private)
lower_string_join :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	pieces := make([dynamic]ir.Value_ID, 0, 4, context.temp_allocator)
	join_pieces(s, id, &pieces)
	return emit_join(s, pieces[:], s.tree.nodes[id].span)
}

// join_length is `.length` of a join, the sum of the lengths of its pieces, as V8 answers it: no cell
// for the join, only the text of a number in it. It fails where the join would.
@(private)
join_length :: proc(s: ^Func_State, id: ast.Node_ID, span: source.Span) -> ir.Value_ID {
	pieces := make([dynamic]ir.Value_ID, 0, 4, context.temp_allocator)
	join_pieces(s, id, &pieces)
	total := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	for value in pieces {
		text := to_string(s, value, span)
		if text == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		length := ir.emit(&s.fb, ir.F64, ir.Length{value = text}, span)
		total = ir.emit(&s.fb, ir.F64, ir.Binary{op = .Add, left = total, right = length}, span)
	}
	limit := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = abi.MAX_STRING_LENGTH}, span)
	too_long := ir.emit(
		&s.fb,
		ir.BOOL,
		ir.Compare{op = .Greater, left = total, right = limit},
		span,
	)
	fail_if(s, too_long, .Invalid_String_Length, span)
	return total
}

@(private)
is_join :: proc(s: ^Func_State, id: ast.Node_ID) -> bool {
	#partial switch v in s.tree.nodes[id].variant {
	case ast.Binary:
		return v.op == .Add && s.typed.node_types[id] == check.STRING
	case ast.Template:
		return true
	}
	return false
}

// join_pieces appends the pieces of a join, left to right, the pieces of a join inside it too. An
// operand of `+` that is not a join is a piece once both sides were evaluated, which is when `+`
// asks for ToPrimitive; an empty part of a template adds nothing.
@(private)
join_pieces :: proc(s: ^Func_State, id: ast.Node_ID, pieces: ^[dynamic]ir.Value_ID) {
	span := s.tree.nodes[id].span
	#partial switch v in s.tree.nodes[id].variant {
	case ast.Binary:
		left, left_lowered := join_operand(s, v.left, pieces)
		left_at := len(pieces) - 1
		right, right_lowered := join_operand(s, v.right, pieces)
		if left_lowered {
			pieces[left_at] = piece(s, left, span, primitive = true)
		}
		if right_lowered {
			pieces[len(pieces) - 1] = piece(s, right, span, primitive = true)
		}
	case ast.Template:
		for part, i in v.parts {
			if len(part) > 0 {
				append(pieces, string_constant(s, part, span))
			}
			if i == len(v.expressions) {
				break
			}
			expression := v.expressions[i]
			if is_join(s, expression) {
				join_pieces(s, expression, pieces)
			} else {
				value := lower_expression(s, expression)
				append(pieces, piece(s, value, s.tree.nodes[expression].span))
			}
		}
	case:
		unreachable()
	}
}

// join_operand appends the pieces of a join, or the operand's value for the caller to make a piece
// of.
@(private)
join_operand :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	pieces: ^[dynamic]ir.Value_ID,
) -> (
	value: ir.Value_ID,
	lowered: bool,
) {
	if is_join(s, id) {
		join_pieces(s, id, pieces)
		return ir.NO_VALUE, false
	}
	value = lower_expression(s, id)
	append(pieces, value)
	return value, true
}

// piece is what String_Join takes of a value: a string or a number as it is, anything else as the
// string to_string makes of it.
@(private)
piece :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	span: source.Span,
	primitive := false,
) -> ir.Value_ID {
	if value != ir.NO_VALUE && value_type(s, value) == ir.F64 {
		return value
	}
	return to_string(s, value, span, primitive)
}

// emit_join answers the string of the pieces, or NO_VALUE when one is missing. A `+=` to a variable
// a loop owns passes the value it held when the loop was entered (owned_entry).
@(private)
emit_join :: proc(
	s: ^Func_State,
	pieces: []ir.Value_ID,
	span: source.Span,
	entry := ir.NO_VALUE,
) -> ir.Value_ID {
	owned := entry != ir.NO_VALUE
	// args[0] is the flag, emitted only once the call is sure.
	args := make([dynamic]ir.Value_ID, 1, len(pieces) + 2, context.temp_allocator)
	if owned {
		append(&args, entry)
	}
	first := len(args)
	for value, i in pieces {
		if value == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		if units, short := short_literal(s, value);
		   short && len(units) == 0 && !(owned && i == 0) {
			continue
		}
		append(&args, value)
	}
	switch len(args) - first {
	case 0:
		return string_constant(s, "", span)
	case 1:
		return to_string(s, args[first], span)
	}
	args[0] = ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = owned}, span)
	for &arg in args[1:] {
		arg = coerce(s, arg, ir.TAGGED, span)
	}
	call := ir.Call_Runtime {
		export = .String_Join,
		args   = args[:],
	}
	return ir.emit(&s.fb, ir.STR, call, span)
}

@(private)
Owned_String :: struct {
	symbol: bind.Symbol_ID,
	loop:   source.Span,
	entry:  ir.Value_ID, // its value when the loop was entered
}

// own_strings finds the string variables a loop may append to in place, since nothing else sees
// their cell while it runs: a `let` of this function declared ahead of the loop, which no function
// reads, and which each use inside the loop keeps no reference of: the target of a `+=` statement,
// `.length`, an index, an operand of a comparison. The first append of each pass through the loop
// still copies, as the value held on entry may be anywhere (str.join).
@(private)
own_strings :: proc(s: ^Func_State, loop: ast.Node_ID, span: source.Span) {
	area := s.tree.nodes[loop].span
	safe := make(map[ast.Node_ID]bool, context.temp_allocator)
	unsafe := make(map[bind.Symbol_ID]bool, context.temp_allocator)
	appended := make([dynamic]bind.Symbol_ID, 0, 4, context.temp_allocator)
	stack := make([dynamic]ast.Node_ID, 0, 64, context.temp_allocator)
	append(&stack, loop)
	// The walk reaches a name after the node that uses it.
	for id in ast.walk(s.tree.nodes, &stack) {
		#partial switch v in s.tree.nodes[id].variant {
		case ast.Ident:
			if !safe[id] || s.bound.node_deferred[id] != bind.MODULE_SCOPE {
				unsafe[s.bound.node_symbols[id]] = true
			}
		case ast.Expr_Stmt:
			assign, is_assign := s.tree.nodes[v.expr].variant.(ast.Assign)
			if is_assign && assign.op == .Add && is_name(s, assign.target) {
				safe[assign.target] = true
				if s.typed.node_types[v.expr] == check.STRING {
					append(&appended, s.bound.node_symbols[assign.target])
				}
			}
		case ast.Member:
			if v.name.text == "length" && is_name(s, v.object) {
				safe[v.object] = true
			}
		case ast.Index:
			if is_name(s, v.object) {
				safe[v.object] = true
			}
		case ast.Binary:
			if _, is_compare := compare_op(v.op); is_compare {
				for operand in ([]ast.Node_ID{v.left, v.right}) {
					if is_name(s, operand) {
						safe[operand] = true
					}
				}
			}
		}
	}

	for symbol, i in appended {
		if slice.contains(appended[:i], symbol) || unsafe[symbol] || !may_own(s, symbol, area) {
			continue
		}
		place, ok := symbol_place(s, {s.file, symbol})
		entry := load_place(s, &place, span) if ok else ir.NO_VALUE
		if entry != ir.NO_VALUE && value_type(s, entry) == ir.STR {
			append(&s.owned, Owned_String{symbol = symbol, loop = area, entry = entry})
		}
	}
}

// may_own checks the variable own_strings found in the loop outside it.
@(private)
may_own :: proc(s: ^Func_State, symbol: bind.Symbol_ID, area: source.Span) -> bool {
	if symbol == bind.NO_SYMBOL || owned_entry(s, symbol, area) != ir.NO_VALUE {
		return false
	}
	entry := s.bound.symbols[symbol]
	declarator, is_declarator := s.tree.nodes[entry.declaration].variant.(ast.Declarator)
	if entry.kind != .Let || !is_declarator || declarator.init == ast.NO_NODE {
		return false
	}
	declared := s.tree.nodes[entry.declaration].span
	if declared.end > area.start ||
	   .Captured in entry.flags ||
	   s.low.closures[s.file].boxed[symbol] {
		return false
	}
	for export in s.bound.exports {
		if export.symbol == symbol {
			return false
		}
	}
	return entry.scope != bind.MODULE_SCOPE || !read_in_functions(s)[symbol]
}

// read_in_functions marks the symbols a function of the file reads, which bind leaves unmarked for
// a module global. Only top-level code asks, so the file is walked once.
@(private)
read_in_functions :: proc(s: ^Func_State) -> []bool {
	if s.read_in_functions != nil {
		return s.read_in_functions
	}
	s.read_in_functions = make([]bool, len(s.bound.symbols), context.temp_allocator)
	for node, i in s.tree.nodes {
		if _, is_ident := node.variant.(ast.Ident); is_ident {
			s.read_in_functions[s.bound.node_symbols[i]] ||=
				s.bound.node_deferred[i] != bind.MODULE_SCOPE
		}
	}
	return s.read_in_functions
}

// owned_entry is what the variable held when the loop around span that owns it was entered, or
// NO_VALUE when no loop does.
@(private)
owned_entry :: proc(s: ^Func_State, symbol: bind.Symbol_ID, span: source.Span) -> ir.Value_ID {
	for owned in s.owned {
		if owned.symbol == symbol && within(span, owned.loop) {
			return owned.entry
		}
	}
	return ir.NO_VALUE
}

@(private)
is_name :: proc(s: ^Func_State, id: ast.Node_ID) -> bool {
	_, is_ident := s.tree.nodes[id].variant.(ast.Ident)
	return is_ident
}

@(private)
within :: proc(inner, outer: source.Span) -> bool {
	return outer.start <= inner.start && inner.end <= outer.end
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
	// Unit_Load reads through a check, and the length test proved this one.
	bounds := ir.Bounds_Check {
		array  = text,
		index  = zero,
		proved = true,
	}
	checked := ir.emit(&s.fb, ir.F64, bounds, span)
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

// lower_split makes the array the runtime fills, of the layout of the call's type: a string[] holds
// its strings tagged where it flows into a wider array type (types.odin).
@(private)
lower_split :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if len(node.args) == 0 {
		return ir.NO_VALUE
	}
	separator := runtime_argument(s, node.args[0], .Ptr)
	limit: ir.Value_ID
	if len(node.args) > 1 {
		limit = optional_argument(s, node.args[1], abi.MISSING_LIMIT, span)
	} else {
		limit = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = abi.MISSING_LIMIT}, span)
	}
	if separator == ir.NO_VALUE || limit == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	type := made_node_type(s, id)
	empty := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	pieces := ir.emit(&s.fb, type, ir.New_Array{layout = type.layout, length = empty}, span)
	split := ir.Call_Runtime {
		export = .String_Split,
		args   = {pieces, receiver, separator, limit},
	}
	ir.emit(&s.fb, ir.VOID, split, span)
	return pieces
}
