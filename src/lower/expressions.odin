package lower

import "core:slice"

import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../program"
import "../source"

/*
Expressions. Every procedure here answers the value the expression produces, or NO_VALUE for one
this build cannot compile. That poison travels: whatever reads it answers poison as well and says
nothing, so a construct is reported once, where it stands, and not again at every use of it. An
expression that has no value, such as console.log or process.exit, answers NO_VALUE too, and
lower_expression tells the two apart by the type check gave the node.

Short-circuit operators, the ternary and the two expanded lib names open blocks of their own and
come back together in a phi, which is also where the locals of the two sides are reconciled.
*/

// lower_expression is the value of an expression, already of the IR type its node was typed with.
//
// It is also the net under poison. An expression check typed with a value that answers NO_VALUE
// while nothing has been reported yet swallowed a construct somewhere below it, and the build
// would succeed with a wrong program; naming the innermost such expression fails it instead. The
// test on the whole list is sound because every declaration a body could read was declared, and
// refused if it had to be, before the first body was built.
lower_expression :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	value := lower_node(s, id)
	if value != ir.NO_VALUE || len(s.low.diagnostics) > 0 {
		return value
	}
	type, ok := ir_type(s.types, s.typed.node_types[id])
	if ok && type != ir.VOID {
		return later(s, s.tree.nodes[id].span, "this expression")
	}
	return ir.NO_VALUE
}

// lower_effect lowers an expression whose value is dropped, as a statement or the init and update
// of a `for` do. A ternary and `&&` or `||` then join no value, so their two sides need not share a
// representation: `debug && console.log(x);` is a branch and nothing more.
@(private)
lower_effect :: proc(s: ^Func_State, id: ast.Node_ID) {
	#partial switch v in s.tree.nodes[id].variant {
	case ast.Binary:
		#partial switch v.op {
		case .And, .Or, .Coalesce:
			lower_logical(s, id, v, ir.VOID)
			return
		}
	case ast.Conditional:
		lower_conditional(s, id, v, ir.VOID)
		return
	}
	lower_expression(s, id)
}

// lower_node is lower_expression without the net: the one switch over the kinds of expression.
@(private)
lower_node :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	#partial switch v in s.tree.nodes[id].variant {
	case ast.Number_Literal:
		return ir.emit(&s.fb, ir.F64, ir.Const_Number{value = v.value}, span)
	case ast.String_Literal:
		text := ir.intern_string(&s.low.builder, v.value)
		return ir.emit(&s.fb, ir.STR, ir.Const_String{text = text}, span)
	case ast.Bool_Literal:
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = v.value}, span)
	case ast.Null_Literal:
		return ir.emit(&s.fb, ir.TAGGED, ir.Const_Null{}, span)
	case ast.Ident:
		return lower_ident(s, id, v)
	case ast.Unary:
		return lower_unary(s, id, v)
	case ast.Update:
		return lower_update(s, id, v)
	case ast.Binary:
		#partial switch v.op {
		case .And, .Or, .Coalesce:
			return lower_logical(s, id, v, node_type(s, id))
		}
		return lower_binary(s, id, v)
	case ast.Assign:
		return lower_assign(s, id, v)
	case ast.Conditional:
		return lower_conditional(s, id, v, node_type(s, id))
	case ast.Call:
		return lower_call(s, id, v)
	case ast.Member:
		return lower_member(s, id, v)
	case ast.As:
		return coerce(s, lower_expression(s, v.expr), node_type(s, id), span)
	case ast.Non_Null:
		return lower_non_null(s, id, v)
	case ast.Template:
		// A template with no substitution is a string literal written with backticks: parse cooked
		// its escapes and left one part behind. Joining the parts of one that does substitute needs
		// a string built at run time, which is the heap of milestone 5.
		if len(v.expressions) == 0 {
			text := ir.intern_string(&s.low.builder, v.parts[0])
			return ir.emit(&s.fb, ir.STR, ir.Const_String{text = text}, span)
		}
		return later(s, span, "template strings")
	case ast.Array_Literal:
		return later(s, span, "arrays")
	case ast.Object_Literal:
		return later(s, span, "objects")
	case ast.Arrow:
		return later(s, span, "arrow functions")
	case ast.Index:
		return later(s, span, "indexing")
	}
	return ir.NO_VALUE
}

// later reports a construct of the v1 language this build does not compile yet, and answers poison.
@(private)
later :: proc(s: ^Func_State, span: source.Span, construct: string) -> ir.Value_ID {
	report(s.low, .Not_Lowered, span, construct)
	return ir.NO_VALUE
}

// node_type is the IR type check gave a node. A type this slice has no room for answers VOID, and
// whoever asked has already reported it or is about to.
@(private)
node_type :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Type {
	type, ok := ir_type(s.types, s.typed.node_types[id])
	return type if ok else ir.VOID
}

// coerce makes a value fit where it is going. The only conversion of this slice is boxing a
// statically typed value into a tagged one; reading one back needs the tag check of milestone 5.
@(private)
coerce :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	target: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	if value == ir.NO_VALUE || target == ir.VOID {
		return value
	}
	have := value_type(s, value)
	if have == target {
		return value
	}
	if target == ir.TAGGED && boxable(have) {
		return ir.emit(&s.fb, ir.TAGGED, ir.Box{value = value}, span)
	}
	if have == ir.VOID {
		// The call of a void function evaluates to undefined, which a tagged value can hold. Any
		// other place check lets a VOID value go is the call of a never function, which does not
		// come back, so nothing reads what it would have converted to.
		if target == ir.TAGGED {
			return ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
		}
		return ir.NO_VALUE
	}
	if have == ir.TAGGED {
		// Reading a statically typed value back out of a tagged one is what narrowing compiles to.
		return later(s, span, "narrowing a union")
	}
	return later(s, span, "this conversion")
}

@(private)
boxable :: proc(type: ir.Type) -> bool {
	#partial switch type.kind {
	case .F64, .Bool, .Str, .Ref, .Closure:
		return true
	}
	return false
}

// truthy is the condition an `if`, a loop or a `!` tests. A number is truthy when its magnitude is
// above zero, which is one intrinsic and one comparison and is false for NaN and for both zeros
// without a branch.
@(private)
truthy :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	if value == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	type := value_type(s, value)
	#partial switch type.kind {
	case .Bool:
		return value
	case .F64:
		size := ir.emit(&s.fb, ir.F64, ir.Intrinsic{op = .Abs, args = {value}}, span)
		zero := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
		test := ir.Compare {
			op    = .Greater,
			left  = size,
			right = zero,
		}
		return ir.emit(&s.fb, ir.BOOL, test, span)
	case .Str:
		return later(s, span, "testing a string for truth")
	case .Tagged:
		return later(s, span, "narrowing a union")
	}
	return ir.NO_VALUE
}

// lower_condition is the boolean an `if`, a loop or a ternary branches on.
@(private)
lower_condition :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	return truthy(s, lower_expression(s, id), s.tree.nodes[id].span)
}

// lower_ident reads a name. check resolved it across files, so the answer names the declaration and
// not the local alias an import gave it.
@(private)
lower_ident :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Ident) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	ref := s.typed.node_symbols[id]
	if ref.symbol == bind.NO_SYMBOL {
		// The only name check types without a symbol is `undefined`.
		if s.typed.node_types[id] == check.UNDEFINED {
			return ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
		}
		return ir.NO_VALUE
	}
	if ref.file == program.LIB {
		return lower_lib_value(s, ref.symbol, span)
	}

	declaration := s.low.prog.bound[ref.file].symbols[ref.symbol].declaration
	if global, is_global := s.low.globals[{ref.file, declaration}]; is_global {
		type := s.low.builder.globals[global].type
		return ir.emit(&s.fb, type, ir.Global_Load{global = global}, span)
	}
	if s.low.prog.bound[ref.file].symbols[ref.symbol].kind == .Function {
		return later(s, span, "function values")
	}
	if ref.file != s.file {
		return ir.NO_VALUE
	}
	return s.locals[ref.symbol]
}

// lower_lib_value reads a name the lib declares. Only the two number constants are a value of their
// own; the rest of the lib is reached through a member or a call.
@(private)
lower_lib_value :: proc(s: ^Func_State, symbol: bind.Symbol_ID, span: source.Span) -> ir.Value_ID {
	name := s.low.prog.bound[program.LIB].symbols[symbol].name.text
	strategy, found := lib_strategy(.Value, name, "")
	if !found {
		return later(s, span, name)
	}
	if constant, is_constant := strategy.(Constant); is_constant {
		return ir.emit(&s.fb, ir.F64, ir.Const_Number{value = constant.value}, span)
	}
	return later(s, span, construct_of(strategy, name))
}

// lower_member reads a field. Everything of an object or an array waits for milestone 5, so what
// stays is a constant of the lib, such as Math.PI.
@(private)
lower_member :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Member) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	strategy, found := member_strategy(s, node)
	if !found {
		return ir.NO_VALUE
	}
	if constant, is_constant := strategy.(Constant); is_constant {
		return ir.emit(&s.fb, ir.F64, ir.Const_Number{value = constant.value}, span)
	}
	return later(s, span, construct_of(strategy, node.name.text))
}

// member_strategy is the table row that `object.name` names. A lib value in front of the dot picks
// the value half of the table by that name; anything else is a method of the type the object turned
// out to have, so the object is lowered to find it out.
@(private)
member_strategy :: proc(s: ^Func_State, node: ast.Member) -> (Strategy, bool) {
	if root, is_lib := lib_root(s, node.object); is_lib {
		return lib_strategy(.Value, root, node.name.text)
	}

	value := lower_expression(s, node.object)
	if value == ir.NO_VALUE {
		return Later{}, false
	}
	owner, has_owner := instance_owner(value_type(s, value))
	if !has_owner {
		return Later{"objects"}, true
	}
	return lib_strategy(.Instance, owner, node.name.text)
}

// lib_root answers the name of the lib value an expression is, as `Math` is in `Math.floor`.
@(private)
lib_root :: proc(s: ^Func_State, id: ast.Node_ID) -> (string, bool) {
	if _, is_ident := s.tree.nodes[id].variant.(ast.Ident); !is_ident {
		return "", false
	}
	ref := s.typed.node_symbols[id]
	if ref.symbol == bind.NO_SYMBOL || ref.file != program.LIB {
		return "", false
	}
	return s.low.prog.bound[program.LIB].symbols[ref.symbol].name.text, true
}

@(private)
lower_non_null :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Non_Null) -> ir.Value_ID {
	value := lower_expression(s, node.expr)
	if value != ir.NO_VALUE && value_type(s, value) == ir.TAGGED {
		// The check that `x!` stands for is a tag test, which milestone 5 brings.
		return later(s, s.tree.nodes[id].span, "narrowing a union")
	}
	return value
}

@(private)
lower_unary :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Unary) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	if node.op == .Typeof {
		return lower_typeof(s, node.operand, span)
	}

	operand := lower_expression(s, node.operand)
	if operand == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	switch node.op {
	case .Plus:
		// Unary plus on a number is nothing to do, and check allows it on nothing else.
		return operand
	case .Minus:
		return unary_number(s, .Negate, operand, span)
	case .Bit_Not:
		return unary_number(s, .Bit_Not, operand, span)
	case .Not:
		test := truthy(s, operand, span)
		if test == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		return ir.emit(&s.fb, ir.BOOL, ir.Unary{op = .Not, operand = test}, span)
	case .Typeof:
		unreachable()
	}
	return ir.NO_VALUE
}

@(private)
unary_number :: proc(
	s: ^Func_State,
	op: ir.Unary_Op,
	operand: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if value_type(s, operand) != ir.F64 {
		return operand_not_lowered(s, operand, span)
	}
	return ir.emit(&s.fb, ir.F64, ir.Unary{op = op, operand = operand}, span)
}

// lower_typeof answers the word for the type the operand already has. A tagged value carries its
// tag at run time, and reading it is the tag test of milestone 5.
@(private)
lower_typeof :: proc(s: ^Func_State, operand: ast.Node_ID, span: source.Span) -> ir.Value_ID {
	word := typeof_word(s, operand)
	if word == "" {
		type := s.typed.node_types[operand]
		if _, ok := ir_type(s.types, type); !ok {
			return later(s, span, construct_text(s.types, type))
		}
		return later(s, span, "`typeof` of a union")
	}
	// The operand of a typeof still runs: it may call something. Reading a name runs nothing, and
	// lowering a name that holds a function would report a function value.
	if _, is_ident := s.tree.nodes[operand].variant.(ast.Ident); !is_ident {
		lower_expression(s, operand)
	}
	return ir.emit(
		&s.fb,
		ir.STR,
		ir.Const_String{text = ir.intern_string(&s.low.builder, word)},
		span,
	)
}

// typeof_word is the word `typeof` answers for the static type of its operand, or "" when only the
// tag of a tagged value could tell.
@(private)
typeof_word :: proc(s: ^Func_State, operand: ast.Node_ID) -> string {
	type := s.typed.node_types[operand]
	switch type {
	case check.UNDEFINED:
		return "undefined"
	case check.NULL:
		return "object"
	}
	#partial switch _ in s.types[type] {
	case check.Function, check.Overload:
		return "function"
	}
	#partial switch node_type(s, operand).kind {
	case .F64:
		return "number"
	case .Bool:
		return "boolean"
	case .Str:
		return "string"
	}
	return ""
}

// lower_binary is an arithmetic operator or a comparison. `&&`, `||` and `??` branch, and are
// lower_logical.
@(private)
lower_binary :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Binary) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	left := lower_expression(s, node.left)
	right := lower_expression(s, node.right)
	if left == ir.NO_VALUE || right == ir.NO_VALUE {
		return ir.NO_VALUE
	}

	if op, is_compare := compare_op(node.op); is_compare {
		return lower_compare(s, op, left, right, span)
	}
	op, is_arithmetic := binary_op(node.op)
	if !is_arithmetic {
		return ir.NO_VALUE
	}
	if value_type(s, left) != ir.F64 || value_type(s, right) != ir.F64 {
		if node.op == .Add && (value_type(s, left) == ir.STR || value_type(s, right) == ir.STR) {
			return later(s, span, "joining strings")
		}
		return operands_not_lowered(s, left, right, span)
	}
	return ir.emit(&s.fb, ir.F64, ir.Binary{op = op, left = left, right = right}, span)
}

// lower_compare answers a boolean. The IR compares two numbers, two booleans or two references
// itself; a string holds its contents and a tagged value its tag, so both go through the runtime,
// which milestone 5 brings.
@(private)
lower_compare :: proc(
	s: ^Func_State,
	op: ir.Compare_Op,
	left, right: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	type := value_type(s, left)
	if type != value_type(s, right) {
		// One side is a tagged value and the other is not, which is a comparison that reads a tag.
		// Nothing else reaches here: check compares two values of one type.
		return later(s, span, "narrowing a union")
	}
	ordered := op != .Equal && op != .Not_Equal
	if type == ir.F64 || (type == ir.BOOL && !ordered) {
		return ir.emit(&s.fb, ir.BOOL, ir.Compare{op = op, left = left, right = right}, span)
	}
	if type == ir.STR {
		return later(s, span, "comparing strings")
	}
	if type == ir.TAGGED {
		return later(s, span, "narrowing a union")
	}
	return ir.NO_VALUE
}

// operand_not_lowered names why an arithmetic operand is not a number: a tagged value narrowing has
// not opened yet, or a string, whose operations are the runtime of milestone 5. It always reports,
// since an operation that goes on without its operand is a wrong program.
@(private)
operand_not_lowered :: proc(
	s: ^Func_State,
	operand: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	#partial switch value_type(s, operand).kind {
	case .Tagged:
		return later(s, span, "narrowing a union")
	case .Str:
		return later(s, span, "string operations")
	}
	return later(s, span, "this operand")
}

// operands_not_lowered is operand_not_lowered for an operator with two sides: it names the side that
// is not a number, the left one when neither is.
@(private)
operands_not_lowered :: proc(
	s: ^Func_State,
	left, right: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if value_type(s, left) != ir.F64 {
		return operand_not_lowered(s, left, span)
	}
	return operand_not_lowered(s, right, span)
}

// lower_logical is `&&`, `||` and `??`. The result is one of the two sides, not a boolean, and the
// side that does not run must not be evaluated, so each opens a block of its own. A result of VOID
// means nobody reads the value, and the two sides meet without a phi.
@(private)
lower_logical :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Binary,
	result: ir.Type,
) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	if node.op == .Coalesce {
		return lower_coalesce(s, node, result, span)
	}

	left := coerce(s, lower_expression(s, node.left), result, span)
	test := truthy(s, left, span)
	if left == ir.NO_VALUE || test == ir.NO_VALUE {
		return ir.NO_VALUE
	}

	other := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	short := here(s)
	branch := ir.Branch {
		condition  = test,
		then_block = other if node.op == .And else join,
		else_block = join if node.op == .And else other,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	values := make([dynamic]ir.Value_ID, 0, 2, context.temp_allocator)
	append(&edges, short)
	append(&values, left)

	ir.use_block(&s.fb, other)
	copy(s.locals, short.values)
	if edge, value, comes_back := lower_arm(s, node.right, join, result, span); comes_back {
		append(&edges, edge)
		append(&values, value)
	}
	return join_values(s, join, edges[:], values[:], result, span)
}

// lower_coalesce is `??`. In this slice the left side is either never nullish, and the right one
// never runs, or it is a tagged value, whose test is the tag check of milestone 5.
@(private)
lower_coalesce :: proc(
	s: ^Func_State,
	node: ast.Binary,
	result: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	switch s.typed.node_types[node.left] {
	case check.UNDEFINED, check.NULL:
		lower_expression(s, node.left)
		return coerce(s, lower_expression(s, node.right), result, span)
	}
	left := lower_expression(s, node.left)
	if left != ir.NO_VALUE && value_type(s, left) == ir.TAGGED {
		return later(s, span, "narrowing a union")
	}
	return coerce(s, left, result, span)
}

// lower_conditional is the ternary: one side runs, and the two meet in a phi. A result of VOID
// means nobody reads the value, and the two sides meet without one.
@(private)
lower_conditional :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Conditional,
	result: ir.Type,
) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	test := lower_condition(s, node.condition)
	if test == ir.NO_VALUE {
		return ir.NO_VALUE
	}

	then_block := ir.add_block(&s.fb)
	else_block := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	entering := here(s)
	branch := ir.Branch {
		condition  = test,
		then_block = then_block,
		else_block = else_block,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	values := make([dynamic]ir.Value_ID, 0, 2, context.temp_allocator)

	ir.use_block(&s.fb, then_block)
	copy(s.locals, entering.values)
	if edge, value, comes_back := lower_arm(s, node.then_value, join, result, span); comes_back {
		append(&edges, edge)
		append(&values, value)
	}

	ir.use_block(&s.fb, else_block)
	copy(s.locals, entering.values)
	if edge, value, comes_back := lower_arm(s, node.else_value, join, result, span); comes_back {
		append(&edges, edge)
		append(&values, value)
	}
	return join_values(s, join, edges[:], values[:], result, span)
}

// lower_arm builds one side of a ternary, or the right side of `&&` and `||`, in the block already
// open for it. An arm check typed never does not come back: process.exit or a function that never
// returns. Its block ends unreachable and it is no edge of the join, so the value of the whole
// expression is what the other side brought.
@(private)
lower_arm :: proc(
	s: ^Func_State,
	arm: ast.Node_ID,
	join: ir.Block_ID,
	result: ir.Type,
	span: source.Span,
) -> (
	edge: Edge,
	value: ir.Value_ID,
	comes_back: bool,
) {
	value = lower_expression(s, arm)
	if s.typed.node_types[arm] == check.NEVER {
		ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		return {}, ir.NO_VALUE, false
	}
	value = coerce(s, value, result, span)
	edge = here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	return edge, value, true
}

// join_values opens a join and adds the phi of the value each edge brought, after the phis that
// reconcile the locals. Every phi of a block stands before its other instructions, which is why
// both are built here and not by the caller.
//
// No phi is built for a VOID type, a value nobody reads, nor when an edge brought poison, which
// makes the whole value poison. When no edge comes back at all, the expression does not either.
@(private)
join_values :: proc(
	s: ^Func_State,
	block: ir.Block_ID,
	edges: []Edge,
	values: []ir.Value_ID,
	type: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	if !open_join(s, block, edges, span) {
		// The statement around the expression may still emit, a `return` or the rest of a
		// console line. It lands in a block nothing reaches, as the statements after a return do.
		ir.use_block(&s.fb, ir.add_block(&s.fb))
		return ir.NO_VALUE
	}
	if type == ir.VOID || slice.contains(values, ir.NO_VALUE) {
		return ir.NO_VALUE
	}
	if len(edges) == 1 {
		return values[0]
	}
	merged := ir.phi(&s.fb, type, span)
	for edge, i in edges {
		ir.phi_incoming(&s.fb, merged, edge.block, values[i])
	}
	return merged
}

// lower_update is `++` and `--`: read the binding, add or subtract one, write it back. The value of
// the expression is the old binding before the operator and the new one after it.
@(private)
lower_update :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Update) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	before := lower_expression(s, node.operand)
	if before == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	if value_type(s, before) != ir.F64 {
		return operand_not_lowered(s, before, span)
	}

	one := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 1}, span)
	op :=
		ir.Binary_Op.Add if node.op == .Pre_Increment || node.op == .Post_Increment else .Subtract
	after := ir.emit(&s.fb, ir.F64, ir.Binary{op = op, left = before, right = one}, span)
	stored, ok := store_target(s, node.operand, after, span)
	if !ok {
		return ir.NO_VALUE
	}
	return stored if node.op == .Pre_Increment || node.op == .Pre_Decrement else before
}

// lower_assign is `=` and every compound form. The value of the expression is what was written.
@(private)
lower_assign :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Assign) -> ir.Value_ID {
	span := s.tree.nodes[id].span

	#partial switch node.op {
	case .And, .Or, .Coalesce:
		return later(s, span, "short-circuit assignment")
	}
	if node.op == .Assign {
		stored, _ := store_target(s, node.target, lower_expression(s, node.value), span)
		return stored
	}

	before := lower_expression(s, node.target)
	right := lower_expression(s, node.value)
	if before == ir.NO_VALUE || right == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	if value_type(s, before) != ir.F64 || value_type(s, right) != ir.F64 {
		if node.op == .Add && value_type(s, before) == ir.STR {
			return later(s, span, "joining strings")
		}
		return operands_not_lowered(s, before, right, span)
	}
	op, ok := binary_op(assign_binary(node.op))
	if !ok {
		return ir.NO_VALUE
	}
	after := ir.emit(&s.fb, ir.F64, ir.Binary{op = op, left = before, right = right}, span)
	stored, _ := store_target(s, node.target, after, span)
	return stored
}

// store_target writes a value into a binding and answers what was written, which is the value of
// the assignment expression. The conversion happens here rather than at the call, so that what a
// binding holds is always of the type the binding was declared with. A field or an element waits
// for milestone 5, and the parser has already refused everything that is no target at all.
@(private)
store_target :: proc(
	s: ^Func_State,
	target: ast.Node_ID,
	value: ir.Value_ID,
	span: source.Span,
) -> (
	ir.Value_ID,
	bool,
) {
	if value == ir.NO_VALUE {
		return ir.NO_VALUE, false
	}
	if _, is_ident := s.tree.nodes[target].variant.(ast.Ident); !is_ident {
		later(s, span, "writing to a field or an element")
		return ir.NO_VALUE, false
	}
	ref := s.typed.node_symbols[target]
	if ref.symbol == bind.NO_SYMBOL {
		return ir.NO_VALUE, false
	}

	declaration := s.low.prog.bound[ref.file].symbols[ref.symbol].declaration
	if global, is_global := s.low.globals[{ref.file, declaration}]; is_global {
		stored := coerce(s, value, s.low.builder.globals[global].type, span)
		if stored == ir.NO_VALUE {
			return ir.NO_VALUE, false
		}
		ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = global, value = stored}, span)
		return stored, true
	}
	if ref.file != s.file || s.locals[ref.symbol] == ir.NO_VALUE {
		return ir.NO_VALUE, false
	}
	stored := coerce(s, value, value_type(s, s.locals[ref.symbol]), span)
	if stored == ir.NO_VALUE {
		return ir.NO_VALUE, false
	}
	s.locals[ref.symbol] = stored
	return stored, true
}

// binary_op and compare_op split the syntactic operators into the two IR instructions they become.

@(private)
binary_op :: proc(op: ast.Binary_Op) -> (ir.Binary_Op, bool) {
	#partial switch op {
	case .Add:
		return .Add, true
	case .Subtract:
		return .Subtract, true
	case .Multiply:
		return .Multiply, true
	case .Divide:
		return .Divide, true
	case .Remainder:
		return .Remainder, true
	case .Power:
		return .Power, true
	case .Shift_Left:
		return .Shift_Left, true
	case .Shift_Right:
		return .Shift_Right, true
	case .Shift_Right_Unsigned:
		return .Shift_Right_Unsigned, true
	case .Bit_And:
		return .Bit_And, true
	case .Bit_Or:
		return .Bit_Or, true
	case .Bit_Xor:
		return .Bit_Xor, true
	}
	return .Add, false
}

@(private)
compare_op :: proc(op: ast.Binary_Op) -> (ir.Compare_Op, bool) {
	#partial switch op {
	case .Less:
		return .Less, true
	case .Less_Equal:
		return .Less_Equal, true
	case .Greater:
		return .Greater, true
	case .Greater_Equal:
		return .Greater_Equal, true
	case .Equal, .Strict_Equal:
		// check allows `==` only between two values of one type, where it is `===` exactly.
		return .Equal, true
	case .Not_Equal, .Strict_Not_Equal:
		return .Not_Equal, true
	}
	return .Equal, false
}

// assign_binary is the operator a compound assignment computes with.
@(private)
assign_binary :: proc(op: ast.Assign_Op) -> ast.Binary_Op {
	#partial switch op {
	case .Add:
		return .Add
	case .Subtract:
		return .Subtract
	case .Multiply:
		return .Multiply
	case .Divide:
		return .Divide
	case .Remainder:
		return .Remainder
	case .Power:
		return .Power
	case .Shift_Left:
		return .Shift_Left
	case .Shift_Right:
		return .Shift_Right
	case .Shift_Right_Unsigned:
		return .Shift_Right_Unsigned
	case .Bit_And:
		return .Bit_And
	case .Bit_Or:
		return .Bit_Or
	case .Bit_Xor:
		return .Bit_Xor
	}
	return .Equal
}
