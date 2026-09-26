package lower

import "core:slice"

import "../abi"
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

// lower_expression is the value of an expression, already of the IR type its node was typed with:
// a tagged value read where check narrowed it is unboxed here (narrowed, unions.odin).
lower_expression :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	return narrowed(s, lower_raw(s, id), id, s.tree.nodes[id].span)
}

// lower_raw is lower_expression without the unbox of a narrowed read, for a consumer that boxes the
// value anyway: console.log, a tagged argument of the runtime, and an expression whose value is
// dropped. check narrows a read by an assignment across calls that may write the variable again
// (narrow.odin), so an unbox there could fail where Node only prints the value.
//
// It is also the net under poison. An expression check typed with a value that answers NO_VALUE
// while nothing has been reported yet swallowed a construct somewhere below it, and the build
// would succeed with a wrong program; naming the innermost such expression fails it instead. The
// test on the whole list is sound because every declaration a body could read was declared, and
// refused if it had to be, before the first body was built.
@(private)
lower_raw :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	value := lower_node(s, id)
	if value != ir.NO_VALUE || len(s.low.diagnostics) > 0 {
		return value
	}
	kind, ok := representation(s.types, s.typed.node_types[id])
	if ok && kind != .Void {
		return later(s, s.tree.nodes[id].span, "this expression")
	}
	return ir.NO_VALUE
}

// lower_effect lowers an expression whose value is dropped, as a statement or the init and update
// of a `for` do. A ternary and `&&` or `||` then join no value, so their two sides need not share a
// representation: `debug && console.log(x);` is a branch and nothing more.
//
// It still answers the value, NO_VALUE for those two, since the body of an arrow typed void gives
// back what a call in it answered (handed_on).
@(private)
lower_effect :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	#partial switch v in s.tree.nodes[id].variant {
	case ast.Binary:
		#partial switch v.op {
		case .And, .Or, .Coalesce:
			lower_logical(s, id, v, ir.VOID)
			return ir.NO_VALUE
		}
	case ast.Conditional:
		lower_conditional(s, id, v, ir.VOID)
		return ir.NO_VALUE
	}
	return lower_raw(s, id)
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
		return lower_as(s, id, v)
	case ast.Non_Null:
		return lower_non_null(s, id, v)
	case ast.Template:
		return lower_template(s, id, v)
	case ast.Array_Literal:
		return lower_array_literal(s, id, v)
	case ast.Object_Literal:
		return lower_object_literal(s, id, v)
	case ast.Arrow:
		// An arrow handed straight to an array method is inlined there and never gets here.
		return make_closure(s, id, span)
	case ast.Index:
		place, ok := lower_place(s, id)
		if !ok {
			return ir.NO_VALUE
		}
		return load_place(s, &place, span)
	}
	return ir.NO_VALUE
}

// later reports a construct of the v1 language this build does not compile yet, and answers poison.
@(private)
later :: proc(s: ^Func_State, span: source.Span, construct: string) -> ir.Value_ID {
	report(s.low, .Not_Lowered, span, construct)
	return ir.NO_VALUE
}

// node_type answers VOID for a type this slice has no room for, and whoever asked has already
// reported it or is about to.
@(private)
node_type :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Type {
	type, ok := ir_type(s.low, s.types, s.typed.node_types[id])
	return type if ok else ir.VOID
}

// coerce boxes a statically typed value into a tagged one, and reads one back after a check that
// fails with mismatch: that is an `any` going into a static type, or a union of objects going into
// one object type that covers every member, whose classes share the layout. Two objects check lets
// meet share one layout, and two functions one signature, so neither ever needs converting into the
// other.
//
// A value of a signature class read as the type a function or a call declares fails with
// Value_Of_Other_Kind instead: the class joined it with a wider one, and a flow through `any`, or
// through a function field written by a narrower object type, brought something else.
@(private)
coerce :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	target: ir.Type,
	span: source.Span,
	mismatch := abi.Runtime_Error.Tagged_Holds_Other_Kind,
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
		return unbox_checked(s, value, target, mismatch, span)
	}
	return later(s, span, "this conversion")
}

// flow_intact is the net under a flow the checker did not record (types.odin): a function that
// moves into a function type of another signature class would be called with arguments it does not
// take, which LLVM may fold into unreachable once it sees both sides. A difference is a checker bug,
// reported rather than compiled.
//
// It also refuses a flow that brings an `any` to a position that may hold a function, at the top
// or nested in a field, a parameter, a result or an element (any_to_function), since only the tag
// of a function out of `any` could be checked: without that, `let f: F | undefined = a; if (f)
// f(1)` would call a closure of any signature through F.
@(private)
flow_intact :: proc(s: ^Func_State, given, wanted: check.Type_ID, span: source.Span) -> bool {
	if found := any_to_function(s.types, given, wanted); found != check.ERROR {
		what := "any" if found == check.ANY else "unknown"
		report(s.low, .Any_Operation, span, "become a function", what)
		return false
	}
	_, given_is_function := s.types[given].(check.Function)
	_, wanted_is_function := s.types[wanted].(check.Function)
	if !given_is_function || !wanted_is_function || given == wanted {
		return true
	}
	from, from_ok := signature_of(s.low, s.types, given)
	to, to_ok := signature_of(s.low, s.types, wanted)
	if !from_ok || !to_ok || signature_equal(from, to) {
		return true
	}
	later(s, span, "a function whose signature this flow changes")
	return false
}

// flow_into moves a value of check type given into a place of check type wanted that holds it as
// target: the checks of flow_checked, then coerce. Every flow check recorded goes through here.
// ERROR on either side stands for a move check recorded nothing about, such as an operator's
// result going back into its place, which needs no check.
@(private)
flow_into :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	given, wanted: check.Type_ID,
	target: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	return coerce(s, flow_checked(s, value, given, wanted, span), target, span)
}

// flow_checked is flow_into without the conversion, for a flow whose conversion comes later: the
// arguments of a call are all evaluated before class_arguments converts the first one.
//
// An `any` or `unknown` given to a union is checked against the members here, as one given to a
// static type is by coerce: the union stays tagged, so no conversion would look at it
// (requirements 3.8).
@(private)
flow_checked :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	given, wanted: check.Type_ID,
	span: source.Span,
) -> ir.Value_ID {
	if value == ir.NO_VALUE || !flow_intact(s, given, wanted, span) {
		return ir.NO_VALUE
	}
	from_any := given == check.ANY || given == check.UNKNOWN
	into_union := wanted != check.ANY && wanted != check.UNKNOWN && is_tagged_type(s, wanted)
	if from_any && into_union && value_type(s, value) == ir.TAGGED {
		check_members(s, value, wanted, .Tagged_Holds_Other_Kind, span)
	}
	return value
}

// is_tagged_type says whether values of the type are tagged: a union of several representations,
// `undefined`, `null`, `any` or `unknown`.
@(private)
is_tagged_type :: proc(s: ^Func_State, type: check.Type_ID) -> bool {
	kind, ok := representation(s.types, type)
	return ok && kind == .Tagged
}

@(private)
boxable :: proc(type: ir.Type) -> bool {
	#partial switch type.kind {
	case .F64, .Bool, .Str, .Ref, .Closure:
		return true
	}
	return false
}

// truthy tests a number by its magnitude being above zero, which is one intrinsic and one
// comparison and is false for NaN and for both zeros without a branch. A string is true when it
// has a unit, and an object, an array and a function always are. A tagged value is tested by
// read_as, the check type it was read with, where the caller knows it (truthy_tagged).
@(private)
truthy :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	span: source.Span,
	read_as := check.ERROR,
) -> ir.Value_ID {
	if value == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	switch value_type(s, value).kind {
	case .Bool:
		return value
	case .F64:
		size := ir.emit(&s.fb, ir.F64, ir.Intrinsic{op = .Abs, args = {value}}, span)
		return above_zero(s, size, span)
	case .Str:
		return above_zero(s, ir.emit(&s.fb, ir.F64, ir.Length{value = value}, span), span)
	case .Ref, .Closure:
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
	case .Tagged:
		return truthy_tagged(s, value, read_as, span)
	case .Void:
	}
	return ir.NO_VALUE
}

@(private)
above_zero :: proc(s: ^Func_State, number: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	zero := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	test := ir.Compare {
		op    = .Greater,
		left  = number,
		right = zero,
	}
	return ir.emit(&s.fb, ir.BOOL, test, span)
}

@(private)
lower_condition :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	return truthy(s, lower_expression(s, id), s.tree.nodes[id].span, s.typed.node_types[id])
}

// lower_ident relies on check having resolved the name across files, so the answer names the
// declaration and not the local alias an import gave it.
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
	if early_use(s.tree, s.bound, id) {
		check_ready(s, s.bound.node_symbols[id], span)
	}
	return lower_symbol(s, ref, span)
}

// lower_symbol reads what a name refers to, wherever it was written: an identifier, or `m.x` of an
// `import * as m`, where check recorded the export on the member.
@(private)
lower_symbol :: proc(s: ^Func_State, ref: check.Symbol_Ref, span: source.Span) -> ir.Value_ID {
	if ref.file == program.LIB {
		return lower_lib_value(s, ref.symbol, span)
	}

	entry := s.low.prog.bound[ref.file].symbols[ref.symbol]
	if global, is_global := s.low.globals[{ref.file, entry.declaration}]; is_global {
		type := s.low.builder.globals[global].type
		return ir.emit(&s.fb, type, ir.Global_Load{global = global}, span)
	}
	if entry.kind == .Function && entry.scope == bind.MODULE_SCOPE {
		// Its one closure, which may be of another module: the name was imported.
		func, declared := s.low.funcs[{ref.file, entry.declaration}]
		if !declared {
			return ir.NO_VALUE // refused where it is declared
		}
		describe_closure(s.low, ref.file, entry.declaration, func)
		return ir.emit(&s.fb, ir.CLOSURE, ir.Func_Ref{func = func}, span)
	}
	if ref.file != s.file {
		return ir.NO_VALUE
	}
	return read_local(s, ref.symbol, span)
}

// lower_lib_value handles the two number constants, the only lib names that are a value of their
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

// lower_member reads, in this order: an export of a module through `import * as m`, a value of the
// lib such as Math.PI or process.argv, a field of an object or of a union of objects, and the
// length of a string, an array or a union of the two. A method named without being called is a
// function value.
@(private)
lower_member :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Member) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	if ref := s.typed.node_symbols[id]; ref.symbol != bind.NO_SYMBOL {
		return lower_symbol(s, ref, span)
	}
	if root, is_lib := lib_root(s, node.object); is_lib {
		strategy, found := lib_strategy(.Value, root, node.name.text)
		if !found {
			return ir.NO_VALUE
		}
		if constant, is_constant := strategy.(Constant); is_constant {
			return ir.emit(&s.fb, ir.F64, ir.Const_Number{value = constant.value}, span)
		}
		if strategy == Builtin.Process_Argv {
			return lower_process_argv(s, span)
		}
		return later(s, span, construct_of(strategy, node.name.text))
	}

	if has_fields(s, node.object) {
		place, ok := lower_place(s, id)
		if !ok {
			return ir.NO_VALUE
		}
		return load_place(s, &place, span)
	}
	receiver := lower_expression(s, node.object)
	if receiver == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	if value_type(s, receiver) == ir.TAGGED && node.name.text == "length" {
		return union_length(s, receiver, s.typed.node_types[node.object], span)
	}
	strategy, found := instance_strategy(s, receiver, node.name.text)
	if !found {
		return ir.NO_VALUE
	}
	if strategy == Builtin.Length {
		return ir.emit(&s.fb, ir.F64, ir.Length{value = receiver}, span)
	}
	return later(s, span, construct_of(strategy, node.name.text))
}

// has_fields says whether an expression is an object, or a union of objects, whose members are
// fields of the program rather than methods of the lib.
@(private)
has_fields :: proc(s: ^Func_State, id: ast.Node_ID) -> bool {
	type := s.typed.node_types[id]
	_, is_object := s.types[type].(check.Object)
	return is_object || is_object_union(s.types, type)
}

// lower_process_argv reads one global, so every read answers the same array, as in Node. main
// fills it before any module runs.
@(private)
lower_process_argv :: proc(s: ^Func_State, span: source.Span) -> ir.Value_ID {
	argv, made := s.low.argv.?
	if !made {
		strings := ir.array_layout(&s.low.builder, .Ref)
		argv = ir.add_global(&s.low.builder, "process.argv", ir.ref(strings))
		s.low.argv = argv
	}
	type := s.low.builder.globals[argv].type
	return ir.emit(&s.fb, type, ir.Global_Load{global = argv}, span)
}

// member_strategy is the table row that `object.name` names, and the receiver it was found on,
// lowered once. A lib value in front of the dot picks the value half of the table by that name and
// has no receiver; anything else is a method of the type the object turned out to have.
@(private)
member_strategy :: proc(
	s: ^Func_State,
	node: ast.Member,
) -> (
	strategy: Strategy,
	receiver: ir.Value_ID,
	found: bool,
) {
	if root, is_lib := lib_root(s, node.object); is_lib {
		strategy, found = lib_strategy(.Value, root, node.name.text)
		return strategy, ir.NO_VALUE, found
	}
	receiver = lower_expression(s, node.object)
	if receiver == ir.NO_VALUE {
		return Later{}, ir.NO_VALUE, false
	}
	strategy, found = instance_strategy(s, receiver, node.name.text)
	return strategy, receiver, found
}

// instance_strategy is the row of a method of a primitive or an array. An object has no methods of
// the lib, and a field of it that holds a function is a function value.
@(private)
instance_strategy :: proc(
	s: ^Func_State,
	receiver: ir.Value_ID,
	name: string,
) -> (
	Strategy,
	bool,
) {
	type := value_type(s, receiver)
	if owner, has_owner := instance_owner(s.low, type); has_owner {
		return lib_strategy(.Instance, owner, name)
	}
	if type == ir.TAGGED {
		// check calls no method of a union: it types the member as a union of signatures.
		return Later{"a method of a union"}, true
	}
	return Later{"calling a function value"}, true
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

// lower_non_null fails the program where the value is null or undefined, and leaves it tagged:
// lower_expression unboxes it into the type check gave `x!`.
@(private)
lower_non_null :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Non_Null) -> ir.Value_ID {
	value := lower_expression(s, node.expr)
	if value != ir.NO_VALUE && value_type(s, value) == ir.TAGGED {
		span := s.tree.nodes[id].span
		fail_if(s, tag_test(s, value, {.Undefined, .Null}, span), .Non_Null_Assertion, span)
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
		test := truthy(s, operand, span, s.typed.node_types[node.operand])
		if test == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		return negated(s, test, span)
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

// lower_binary never sees `&&`, `||` and `??`: they branch, and are lower_logical.
@(private)
lower_binary :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Binary) -> ir.Value_ID {
	if test, matched := lower_typeof_test(s, id, node); matched {
		return test
	}
	span := s.tree.nodes[id].span
	left := lower_expression(s, node.left)
	right := lower_expression(s, node.right)
	if left == ir.NO_VALUE || right == ir.NO_VALUE {
		return ir.NO_VALUE
	}

	if op, is_compare := compare_op(node.op); is_compare {
		return lower_compare(s, op, {left, right}, span)
	}
	op, is_arithmetic := binary_op(node.op)
	if !is_arithmetic {
		return ir.NO_VALUE
	}
	return arithmetic(s, op, left, right, span)
}

// arithmetic is `+` of a string and anything, which joins them, or an operator on two numbers.
@(private)
arithmetic :: proc(
	s: ^Func_State,
	op: ir.Binary_Op,
	left, right: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if op == .Add && (value_type(s, left) == ir.STR || value_type(s, right) == ir.STR) {
		return lower_concat(s, left, right, span)
	}
	if value_type(s, left) != ir.F64 || value_type(s, right) != ir.F64 {
		return operands_not_lowered(s, left, right, span)
	}
	return ir.emit(&s.fb, ir.F64, ir.Binary{op = op, left = left, right = right}, span)
}

// lower_compare lets the IR compare two numbers, two booleans or two references itself; a string
// holds its contents and goes through the runtime, and so does a tagged value, unless the other
// side is null or undefined (compare_tagged). Two objects check lets `===` compare share one layout,
// so their references compare as they are.
@(private)
lower_compare :: proc(
	s: ^Func_State,
	op: ir.Compare_Op,
	values: [2]ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	left, right := values[0], values[1]
	ordered := op != .Equal && op != .Not_Equal
	if value_type(s, left) == ir.TAGGED || value_type(s, right) == ir.TAGGED {
		if ordered {
			// check orders two numbers or two strings, and `any` not at all.
			return later(s, span, "ordering a tagged value")
		}
		return compare_tagged(s, op, values, span)
	}
	type := value_type(s, left)
	if type != value_type(s, right) {
		// check compares two values of one type, and gives two objects it lets meet one layout.
		return later(s, span, "comparing two representations")
	}
	switch type.kind {
	case .F64:
		return ir.emit(&s.fb, ir.BOOL, ir.Compare{op = op, left = left, right = right}, span)
	case .Bool, .Ref, .Closure:
		if !ordered {
			return ir.emit(&s.fb, ir.BOOL, ir.Compare{op = op, left = left, right = right}, span)
		}
	case .Str:
		return compare_strings(s, op, left, right, span)
	case .Tagged, .Void:
	}
	return ir.NO_VALUE
}

// operand_not_lowered is the net under an arithmetic operand that is not a number, which check
// refuses. It always reports, since an operation that goes on without its operand is a wrong
// program.
@(private)
operand_not_lowered :: proc(
	s: ^Func_State,
	operand: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	#partial switch value_type(s, operand).kind {
	case .Tagged:
		return later(s, span, "arithmetic on a tagged value")
	case .Str:
		return later(s, span, "string operations")
	}
	return later(s, span, "this operand")
}

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

// lower_logical answers one of the two sides, not a boolean, and the side that does not run must
// not be evaluated, so each opens a block of its own. A result of VOID means nobody reads the
// value, and the two sides meet without a phi.
//
// The left side is tested in its own type: truthy for `&&` and `||`, and for `??` neither null nor
// undefined, where only a tagged value can be either. It turns into the type of the result on the
// edge that keeps it: boxed before the branch, or unboxed after it in a block of its own, since
// `name || "none"` is a string exactly where name is truthy.
@(private)
lower_logical :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Binary,
	result: ir.Type,
) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	wanted := joined_type(s, id, result)
	// `??` reads the left side as it is (lower_raw), not as check narrowed it: a call may have
	// written the variable since. Only its value decides a side that never runs.
	left: ir.Value_ID
	if node.op == .Coalesce {
		left = lower_raw(s, node.left)
		switch {
		case is_nullish_constant(s, left):
			right := lower_expression(s, node.right)
			return flow_into(s, right, s.typed.node_types[node.right], wanted, result, span)
		case left != ir.NO_VALUE && value_type(s, left) != ir.TAGGED:
			// Never nullish, so the right side never runs.
			return flow_into(s, left, s.typed.node_types[node.left], wanted, result, span)
		}
	} else {
		left = lower_expression(s, node.left)
	}
	if left == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	test: ir.Value_ID
	if node.op == .Coalesce {
		test = negated(s, tag_test(s, left, {.Undefined, .Null}, span), span)
	} else {
		test = truthy(s, left, span, s.typed.node_types[node.left])
	}
	unboxing := value_type(s, left) == ir.TAGGED && result != ir.VOID && result != ir.TAGGED
	kept := left
	if !unboxing {
		kept = flow_into(s, left, s.typed.node_types[node.left], wanted, result, span)
	}
	if test == ir.NO_VALUE || kept == ir.NO_VALUE {
		return ir.NO_VALUE
	}

	other := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	keep := join
	if unboxing {
		keep = ir.add_block(&s.fb)
	}
	entering := here(s)
	// `&&` keeps the left side where it is falsy, `||` and `??` where the test holds.
	branch := ir.Branch {
		condition  = test,
		then_block = other if node.op == .And else keep,
		else_block = keep if node.op == .And else other,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	values := make([dynamic]ir.Value_ID, 0, 2, context.temp_allocator)
	if unboxing {
		ir.use_block(&s.fb, keep)
		kept = unbox_checked(s, left, result, .Tagged_Holds_Other_Kind, span)
		append(&edges, here(s))
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	} else {
		append(&edges, entering)
	}
	append(&values, kept)

	ir.use_block(&s.fb, other)
	copy(s.locals, entering.values)
	edge, value, comes_back := lower_arm(s, node.right, join, result, wanted, span)
	if comes_back {
		append(&edges, edge)
		append(&values, value)
	}
	return join_values(s, join, edges[:], values[:], result, span)
}

// lower_conditional takes a result of VOID to mean nobody reads the value, and the two sides then
// meet without a phi.
@(private)
lower_conditional :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Conditional,
	result: ir.Type,
) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	wanted := joined_type(s, id, result)
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

	arms := [2]ast.Node_ID{node.then_value, node.else_value}
	blocks := [2]ir.Block_ID{then_block, else_block}
	for arm, i in arms {
		ir.use_block(&s.fb, blocks[i])
		copy(s.locals, entering.values)
		edge, value, comes_back := lower_arm(s, arm, join, result, wanted, span)
		if comes_back {
			append(&edges, edge)
			append(&values, value)
		}
	}
	return join_values(s, join, edges[:], values[:], result, span)
}

// joined_type is the check type the sides of a ternary, or of `&&`, `||` and `??`, flow into: the
// whole expression's, and none where nobody reads the value.
@(private)
joined_type :: proc(s: ^Func_State, id: ast.Node_ID, result: ir.Type) -> check.Type_ID {
	return s.typed.node_types[id] if result != ir.VOID else check.ERROR
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
	wanted: check.Type_ID,
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
	value = flow_into(s, value, s.typed.node_types[arm], wanted, result, span)
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

@(private)
lower_update :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Update) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	place, ok := lower_place(s, node.operand)
	if !ok {
		return ir.NO_VALUE
	}
	before := narrowed(s, load_place(s, &place, span), node.operand, span)
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
	if store_place(s, &place, after, span) == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	return after if node.op == .Pre_Increment || node.op == .Pre_Decrement else before
}

// lower_assign answers what was written, which is the value of the expression. The place is
// evaluated before the value, as in JavaScript: `a[i] = (i = 5)` writes at the old i.
@(private)
lower_assign :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Assign) -> ir.Value_ID {
	span := s.tree.nodes[id].span

	#partial switch node.op {
	case .And, .Or, .Coalesce:
		return later(s, span, "short-circuit assignment")
	}
	place, ok := lower_place(s, node.target)
	if node.op == .Assign {
		value := lower_expression(s, node.value)
		if !ok {
			return ir.NO_VALUE
		}
		given, wanted := s.typed.node_types[node.value], s.typed.node_types[node.target]
		return store_place(s, &place, value, span, given, wanted)
	}

	before := narrowed(s, load_place(s, &place, span), node.target, span) if ok else ir.NO_VALUE
	right := lower_expression(s, node.value)
	if before == ir.NO_VALUE || right == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	op, is_arithmetic := binary_op(assign_binary(node.op))
	if !is_arithmetic {
		return ir.NO_VALUE
	}
	return store_place(s, &place, arithmetic(s, op, before, right, span), span)
}

// Places: where an assignment, an update or a read of a field or an element goes.

@(private)
// Local_Place and Global_Place are early where the name may be used before its declaration ran
// (early_use): the first load or store tests that it has (check_ready).
Local_Place :: struct {
	symbol: bind.Symbol_ID,
	early:  bool,
}

@(private)
Global_Place :: struct {
	global: ir.Global_ID,
	symbol: bind.Symbol_ID,
	early:  bool,
}

// Field_Place names a slot of the cell's layout. type is what a read answers, the field's declared
// type, which a widened slot may hold boxed (objects.odin).
@(private)
Field_Place :: struct {
	cell:  ir.Value_ID,
	field: i32,
	type:  ir.Type,
}

// Element_Place holds the index as the program wrote it until a read checks it, and a write checks
// it again, where it may append (arrays.odin).
@(private)
Element_Place :: struct {
	array:   ir.Value_ID, // an array Ref, or a Str, which only a read may take
	index:   ir.Value_ID,
	checked: bool, // index is the answer of the Bounds_Check of a read
	type:    ir.Type, // the element's declared type
}

@(private)
Place :: union {
	Local_Place,
	Global_Place,
	Field_Place,
	Element_Place,
	Union_Field_Place,
}

// lower_place evaluates what the place needs and nothing more: the object of a field, the array and
// the index of an element. It answers false for a place with nothing to write to, reported where
// the reason was found or before.
@(private)
lower_place :: proc(s: ^Func_State, target: ast.Node_ID) -> (place: Place, ok: bool) {
	span := s.tree.nodes[target].span
	#partial switch v in s.tree.nodes[target].variant {
	case ast.Ident:
		early := early_use(s.tree, s.bound, target)
		return symbol_place(s, s.typed.node_symbols[target], early)
	case ast.Member:
		if ref := s.typed.node_symbols[target]; ref.symbol != bind.NO_SYMBOL {
			return symbol_place(s, ref)
		}
		cell := lower_expression(s, v.object)
		if cell == ir.NO_VALUE {
			return nil, false
		}
		type := s.typed.node_types[v.object]
		if is_object_union(s.types, type) && value_type(s, cell) == ir.TAGGED {
			return union_field_place(s, cell, type, v.name.text, span)
		}
		object, is_object := s.types[type].(check.Object)
		if !is_object || value_type(s, cell).kind != .Ref {
			// check reads a field of an object or of a union of objects, and nothing else.
			later(s, span, "a field of this value")
			return nil, false
		}
		return field_place(s, cell, object, v.name.text)
	case ast.Index:
		return element_place(s, v, span)
	}
	// parse has refused everything else a program could write to.
	return nil, false
}

@(private)
symbol_place :: proc(
	s: ^Func_State,
	ref: check.Symbol_Ref,
	early := false,
) -> (
	place: Place,
	ok: bool,
) {
	if ref.symbol == bind.NO_SYMBOL {
		return nil, false
	}
	declaration := s.low.prog.bound[ref.file].symbols[ref.symbol].declaration
	if global, is_global := s.low.globals[{ref.file, declaration}]; is_global {
		return Global_Place{global = global, symbol = ref.symbol, early = early}, true
	}
	if ref.file != s.file || is_refused(s, ref.symbol) {
		return nil, false
	}
	return Local_Place{symbol = ref.symbol, early = early}, true
}

// load_place may check the index of an element, and the place keeps the answer, so a write after
// the read goes to the index the read checked.
@(private)
load_place :: proc(s: ^Func_State, place: ^Place, span: source.Span) -> ir.Value_ID {
	switch &p in place {
	case Local_Place:
		if p.early {
			check_ready(s, p.symbol, span)
			p.early = false
		}
		return read_local(s, p.symbol, span)
	case Global_Place:
		if p.early {
			check_ready(s, p.symbol, span)
			p.early = false
		}
		type := s.low.builder.globals[p.global].type
		return ir.emit(&s.fb, type, ir.Global_Load{global = p.global}, span)
	case Field_Place:
		return load_field(s, p, span)
	case Element_Place:
		return load_element(s, &p, span)
	case Union_Field_Place:
		return load_union_field(s, p, span)
	}
	return ir.NO_VALUE
}

// store_place converts the value into the type the place holds, so a binding always holds the type
// it was declared with, and answers the value as it came, which is the value of the assignment. A
// binding typed `never`, as in `const n: never = s` after a switch that covered every member, holds
// nothing: the value is not written, or a join would meet a value where it expects none.
//
// given and wanted are the check types of the flow (flow_into). A field of a union of objects takes
// only the net here: each member converts the value into its own slot.
@(private)
store_place :: proc(
	s: ^Func_State,
	place: ^Place,
	value: ir.Value_ID,
	span: source.Span,
	given := check.ERROR,
	wanted := check.ERROR,
) -> ir.Value_ID {
	if value == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	switch &p in place {
	case Local_Place:
		type := local_type(s, p.symbol)
		if type == ir.VOID {
			return value
		}
		stored := flow_into(s, value, given, wanted, type, span)
		if stored == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		if p.early {
			check_ready(s, p.symbol, span)
		}
		write_local(s, p.symbol, stored, span)
	case Global_Place:
		type := s.low.builder.globals[p.global].type
		if type == ir.VOID {
			return value
		}
		stored := flow_into(s, value, given, wanted, type, span)
		if stored == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		if p.early {
			check_ready(s, p.symbol, span)
		}
		ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = p.global, value = stored}, span)
	case Field_Place:
		stored := flow_into(s, value, given, wanted, p.type, span)
		if !store_field(s, p, stored, span) {
			return ir.NO_VALUE
		}
	case Element_Place:
		stored := flow_into(s, value, given, wanted, p.type, span)
		if !store_element(s, p, stored, span) {
			return ir.NO_VALUE
		}
	case Union_Field_Place:
		if !flow_intact(s, given, wanted, span) || !store_union_field(s, p, value, span) {
			return ir.NO_VALUE
		}
	}
	return value
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
