package lower

import "core:fmt"

import "../abi"
import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../program"
import "../source"

/*
Calls, and with them the whole of the standard library. A call is one of three things: a function of
the program that takes no environment, named by its name, which resolves statically and becomes a
direct call; a name of the lib, which the strategy table of lib.odin turns into an intrinsic, an
operator, a runtime call or a shape built here; or anything else that holds a function value, which
is a call through the closure (closures.odin).

Both kinds of call to the program pass the arguments of the callee's signature class (types.odin):
each boxed where the class is wider than the call's own type, one the call leaves out as the zero of
its class type, undefined for a tagged one. The answer comes back in the class type and is unboxed
into the type the call has (coerce). A call typed void answers what came back as it is, since Node
does: `console.log(f())` prints what f returned even where its type says it returns nothing.

A method is called on its receiver, which is lowered once, before the arguments, as JavaScript
evaluates it. `m.f()` through an `import * as m` is no method call: check recorded the export on the
member, and the call is a direct one.

console.log is one runtime call per statement, with every argument boxed into a tagged value: a
format string in the first argument decides how the others print, so only the runtime can lay out
the line. Every argument is evaluated before the call, as Node does it.
*/

@(private)
lower_call :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Call) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	ref := s.typed.node_symbols[node.callee]
	member, is_member := s.tree.nodes[node.callee].variant.(ast.Member)
	if is_member && ref.symbol == bind.NO_SYMBOL {
		// A field of an object that holds a function is called as any function value is.
		if _, is_lib := lib_root(s, member.object); is_lib || !has_fields(s, member.object) {
			return lower_method_call(s, id, node, member, span)
		}
	}
	if ref.symbol != bind.NO_SYMBOL && ref.file == program.LIB {
		name := s.low.prog.bound[program.LIB].symbols[ref.symbol].name.text
		strategy, found := lib_strategy(.Value, name, "")
		if !found {
			return ir.NO_VALUE
		}
		return lower_strategy(s, id, node, strategy, name, ir.NO_VALUE, span)
	}

	callee, ok := call_target(s, node.callee, span)
	if !ok {
		return ir.NO_VALUE
	}
	given, given_ok := lower_arguments(s, node)
	if !given_ok {
		return ir.NO_VALUE
	}
	return emit_class_call(s, callee, given, len(given), node_type(s, id), span)
}

@(private)
lower_method_call :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	member: ast.Member,
	span: source.Span,
) -> ir.Value_ID {
	strategy, receiver, found := member_strategy(s, member)
	if !found {
		return ir.NO_VALUE
	}
	return lower_strategy(s, id, node, strategy, member.name.text, receiver, span)
}

// Callee is what a call of the program calls, by its class signature: a declared function that
// takes no environment, directly, or a function value, through its closure.
@(private)
Callee :: struct {
	func:      ir.Func_ID, // called directly when closure is NO_VALUE
	closure:   ir.Value_ID,
	signature: Signature,
}

// call_target evaluates a function value once, before the arguments, as JavaScript does; the name
// of a declared function with no environment evaluates nothing. span is where a function type with
// no signature is reported.
@(private)
call_target :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	span: source.Span,
) -> (
	callee: Callee,
	ok: bool,
) {
	#partial switch _ in s.tree.nodes[id].variant {
	case ast.Ident, ast.Member:
		ref := s.typed.node_symbols[id]
		if ref.symbol == bind.NO_SYMBOL {
			break
		}
		declared := s.low.prog.bound[ref.file].symbols[ref.symbol]
		func, found := s.low.funcs[{ref.file, declared.declaration}]
		if found && s.low.builder.funcs[func].env == ir.NO_LAYOUT {
			body := s.low.builder.funcs[func]
			signature := Signature {
				params = body.params,
				result = body.result,
			}
			return {func = func, closure = ir.NO_VALUE, signature = signature}, true
		}
		if declared.kind == .Function && !found {
			// The declaration was refused where it stands; a use of it says nothing more.
			return {}, false
		}
	}
	closure := lower_expression(s, id)
	if closure == ir.NO_VALUE {
		return {}, false
	}
	type := s.typed.node_types[id]
	signature, has_signature := signature_of(s.low, s.types, type)
	if !has_signature {
		later(s, span, construct_text(s.types, type))
		return {}, false
	}
	return {closure = closure, signature = signature}, true
}

// lower_arguments evaluates every argument in order, then checks the flow of each into its
// parameter (flow_checked); class_arguments converts them.
@(private)
lower_arguments :: proc(s: ^Func_State, node: ast.Call) -> (args: []ir.Value_ID, ok: bool) {
	function, is_function := s.types[s.typed.node_types[node.callee]].(check.Function)
	args = make([]ir.Value_ID, len(node.args), context.temp_allocator)
	for arg, i in node.args {
		args[i] = lower_expression(s, arg)
	}
	ok = true
	for arg, i in node.args {
		if is_function && i < len(function.params) {
			given, wanted := s.typed.node_types[arg], function.params[i].type
			args[i] = flow_checked(s, args[i], given, wanted, s.tree.nodes[arg].span)
		}
		ok &&= args[i] != ir.NO_VALUE
	}
	return
}

// emit_class_call calls with the arguments of the callee's class (class_arguments), the first
// count of them given, and reads the answer as want.
@(private)
emit_class_call :: proc(
	s: ^Func_State,
	callee: Callee,
	given: []ir.Value_ID,
	count: int,
	want: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	args, ok := class_arguments(s, callee.signature, given, count, span)
	if !ok {
		return ir.NO_VALUE
	}
	call: ir.Variant = ir.Call {
		func = callee.func,
		args = args,
	}
	if callee.closure != ir.NO_VALUE {
		call = ir.Call_Closure {
			callee = callee.closure,
			args   = args,
		}
	}
	value := ir.emit(&s.fb, callee.signature.result, call, span)
	return coerce(s, value, want, span, .Value_Of_Other_Kind)
}

// class_arguments passes the first `count` of the given values, each boxed into its class type
// where the class is wider, and fills every other position of the class with the zero of its type,
// which is undefined for a tagged one: a value a function does not take must not land where
// another member of its class takes something else.
@(private)
class_arguments :: proc(
	s: ^Func_State,
	signature: Signature,
	given: []ir.Value_ID,
	count: int,
	span: source.Span,
) -> (
	args: []ir.Value_ID,
	ok: bool,
) {
	args = make([]ir.Value_ID, len(signature.params), context.temp_allocator)
	for param, i in signature.params {
		if i < count {
			args[i] = coerce(s, given[i], param, span)
		} else {
			args[i] = zero_value(s, param, span)
		}
		if args[i] == ir.NO_VALUE {
			return nil, false
		}
	}
	return args, true
}

// Callbacks.

// Callback is what an array method calls for each element: an arrow written in the call, inlined
// (inline_arrow), or anything else, called through call_target.
@(private)
Callback :: struct {
	arrow:    ast.Node_ID, // NO_NODE unless the callback is inlined
	callee:   Callee, // what is called when the callback is not inlined
	function: check.Function, // the callback's own type
	result:   ir.Type, // its own result; VOID when the callback returns nothing
}

// callback_of evaluates a function value once, here, before the loop that calls it.
@(private)
callback_of :: proc(s: ^Func_State, id: ast.Node_ID) -> (callback: Callback, ok: bool) {
	span := s.tree.nodes[id].span
	function := s.types[s.typed.node_types[id]].(check.Function) or_return
	result, representable := ir_type(s.low, s.types, function.result)
	if !representable {
		later(s, span, construct_text(s.types, function.result))
		return {}, false
	}
	callback = {
		arrow    = ast.NO_NODE,
		function = function,
		result   = result,
	}
	if s.low.closures[s.file].inlined[id] {
		callback.arrow = id
		return callback, true
	}
	callback.callee = call_target(s, id, span) or_return
	return callback, true
}

// call_callback passes the callback as many of the arguments as its own type takes: the index must
// not land in a position where another member of its signature class takes a string. given holds
// the check type of each argument.
@(private)
call_callback :: proc(
	s: ^Func_State,
	callback: Callback,
	args: []ir.Value_ID,
	given: []check.Type_ID,
	span: source.Span,
) -> ir.Value_ID {
	if callback.arrow != ast.NO_NODE {
		return inline_arrow(s, callback, args, given, span)
	}
	params := callback.function.params
	count := min(len(args), len(params))
	flowed := make([]ir.Value_ID, count, context.temp_allocator)
	for i in 0 ..< count {
		target := callback.callee.signature.params[i]
		flowed[i] = flow_into(s, args[i], given[i], params[i].type, target, span)
	}
	return emit_class_call(s, callback.callee, flowed, count, callback.result, span)
}

// called_as_it_stands says whether a signature takes what the runtime passes a comparator: two
// elements of the array, as C types, and a number back.
@(private)
called_as_it_stands :: proc(signature: Signature, element: ir.Type) -> bool {
	if len(signature.params) != 2 || signature.result != ir.F64 {
		return false
	}
	return signature.params[0].kind == element.kind && signature.params[1].kind == element.kind
}

// sort_adapter answers a function of the runtime's comparator shape that calls the closure its
// environment holds through the closure's class signature: the first `takes` elements boxed into
// the class, the other positions of the class at their zero, and the answer unboxed into a number.
// One adapter serves every comparator of one class, element kind and count. It is built on the
// spot, in the middle of the function that needs it: declare_func appends a row and end_func
// writes it back by index, so the function being built is not disturbed.
@(private)
sort_adapter :: proc(
	low: ^Lowering,
	file: source.File_ID,
	call: ast.Node_ID,
	signature: Signature,
	element: ir.Type,
	takes: int,
	span: source.Span,
) -> ir.Func_ID {
	key := fmt.tprintf("%s/%d/%d", signature_key(signature), element.kind, takes)
	if func, built := low.sort_adapters[key]; built {
		return func
	}

	env := ir.environment_layout(&low.builder, {.Ref})
	name := fmt.aprintf("m%d.sort$%d", file, call, allocator = low.allocator)
	params := [2]ir.Type{element, element}
	func := ir.declare_func(&low.builder, name, params[:], ir.F64, span, env)
	ir.describe_func(&low.builder, func, "", len(params), false)
	low.sort_adapters[key] = func

	// No tree and no locals: nothing here reads the program.
	a := Func_State {
		low      = low,
		fb       = ir.begin_func(&low.builder, func),
		file     = file,
		result   = ir.F64,
		declared = ir.F64,
	}
	cell := ir.emit(&a.fb, ir.ref(env), ir.Env{}, span)
	callee := Callee {
		closure   = ir.emit(&a.fb, ir.CLOSURE, ir.Field_Load{cell = cell, field = 0}, span),
		signature = signature,
	}
	given := [2]ir.Value_ID{ir.Value_ID(0), ir.Value_ID(1)}
	answer := emit_class_call(&a, callee, given[:], takes, ir.F64, span)
	if answer == ir.NO_VALUE {
		ir.emit(&a.fb, ir.VOID, ir.Unreachable{}, span) // reported where it was found
	} else {
		ir.emit(&a.fb, ir.VOID, ir.Return{value = answer}, span)
	}
	ir.end_func(&a.fb)
	return func
}

// lower_strategy takes the receiver of a method, and NO_VALUE for a name of the lib.
@(private)
lower_strategy :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	strategy: Strategy,
	name: string,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	switch v in strategy {
	case Later:
		return later(s, span, v.construct)
	case Constant:
		// A constant is not callable, and check said so already.
		return ir.NO_VALUE
	case Intrinsic:
		args, ok := number_args(s, node, 2 if v.op == .Atan2 else 1)
		if !ok {
			return ir.NO_VALUE
		}
		return ir.emit(&s.fb, ir.F64, ir.Intrinsic{op = v.op, args = args}, span)
	case Operator:
		args, ok := number_args(s, node, 2)
		if !ok {
			return ir.NO_VALUE
		}
		return ir.emit(&s.fb, ir.F64, ir.Binary{op = v.op, left = args[0], right = args[1]}, span)
	case Runtime:
		return lower_runtime(s, id, node, v.export, span)
	case Method:
		return lower_method(s, id, node, v, receiver, span)
	case Fold:
		return lower_fold(s, node, v, span)
	case Builtin:
		switch v {
		case .Console_Log:
			return lower_console(s, node, false, span)
		case .Console_Error:
			return lower_console(s, node, true, span)
		case .Process_Argv, .Length:
			// A value, not callable, and check said so already.
			return ir.NO_VALUE
		case .Process_Exit:
			return lower_process_exit(s, node, span)
		case .Number_Is_Integer:
			return lower_is_integer(s, node, span)
		case .Math_Sign:
			return lower_sign(s, node, span)
		case .String_Of:
			return lower_string_of(s, node, span)
		case .String_Includes:
			return lower_string_includes(s, node, receiver, span)
		case .Array_Push:
			return lower_push(s, node, receiver, span)
		case .Array_Join:
			return lower_join(s, node, receiver, span)
		case .Array_Sort:
			return lower_sort(s, id, node, receiver, span)
		case .Array_Map:
			return lower_map(s, id, node, receiver, span)
		case .Array_Filter:
			return lower_filter(s, id, node, receiver, span)
		case .Array_For_Each:
			return lower_for_each(s, node, receiver, span)
		case .Array_Reduce:
			return lower_reduce(s, id, node, receiver, span)
		}
	}
	return later(s, span, name)
}

// runtime_argument lowers an argument and hands it over in the C type its row declares: boxed for a
// tagged parameter, where a narrowed read stays as it is (lower_raw), a reference as it is, and a
// tagged value unboxed after a check where the parameter is static.
@(private)
runtime_argument :: proc(s: ^Func_State, arg: ast.Node_ID, param: abi.C_Type) -> ir.Value_ID {
	span := s.tree.nodes[arg].span
	value: ir.Value_ID
	if param == .Tagged {
		value = lower_raw(s, arg)
	} else {
		value = lower_expression(s, arg)
	}
	if value == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	#partial switch param {
	case .Number:
		return coerce(s, value, ir.F64, span)
	case .Boolean:
		return coerce(s, value, ir.BOOL, span)
	case .Tagged:
		return coerce(s, value, ir.TAGGED, span)
	case .Ptr:
		#partial switch value_type(s, value).kind {
		case .Str, .Ref, .Closure:
			return value
		case .Tagged:
			// Every reference an argument of the lib passes here is a string: a search, a
			// separator, a text.
			return coerce(s, value, ir.STR, span)
		}
	}
	return operand_not_lowered(s, value, span)
}

// optional_number hands over a number argument that may be undefined at run time as the number the
// specification treats exactly as undefined there (abi.MISSING_END and its kin), which is what the
// runtime takes for an argument the call leaves out.
@(private)
optional_number :: proc(
	s: ^Func_State,
	arg: ast.Node_ID,
	missing: f64,
	span: source.Span,
) -> ir.Value_ID {
	value := lower_expression(s, arg)
	if value == ir.NO_VALUE || value_type(s, value) != ir.TAGGED {
		return coerce(s, value, ir.F64, s.tree.nodes[arg].span)
	}
	absent := ir.add_block(&s.fb)
	given := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	branch := ir.Branch {
		condition  = tag_test(s, value, {.Undefined}, span),
		then_block = absent,
		else_block = given,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, absent)
	stand_in := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = missing}, span)
	left_out := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	ir.use_block(&s.fb, given)
	number := unbox_checked(s, value, ir.F64, .Tagged_Holds_Other_Kind, s.tree.nodes[arg].span)
	passed := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	return join_values(s, join, {left_out, passed}, {stand_in, number}, ir.F64, span)
}

// lower_runtime stays quiet about a call with the wrong count: check already reported it.
@(private)
lower_runtime :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	export: abi.Runtime_Proc,
	span: source.Span,
) -> ir.Value_ID {
	exports := abi.RUNTIME_EXPORTS
	params := exports[export].params
	if len(node.args) != len(params) {
		return ir.NO_VALUE
	}
	args := make([]ir.Value_ID, len(params), context.temp_allocator)
	complete := true
	for arg, i in node.args {
		args[i] = runtime_argument(s, arg, params[i])
		complete &&= args[i] != ir.NO_VALUE
	}
	if !complete {
		return ir.NO_VALUE
	}
	return ir.emit(&s.fb, node_type(s, id), ir.Call_Runtime{export = export, args = args}, span)
}

// lower_method passes the receiver first. An argument the call leaves out, always a number, takes
// the row's stand-in for undefined.
@(private)
lower_method :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	method: Method,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	exports := abi.RUNTIME_EXPORTS
	params := exports[method.export].params
	args := make([]ir.Value_ID, len(params), context.temp_allocator)
	args[0] = receiver
	complete := true
	for param, i in params[1:] {
		switch {
		case i < len(node.args) && param == .Number:
			args[i + 1] = optional_number(s, node.args[i], method.missing[i], span)
		case i < len(node.args):
			args[i + 1] = runtime_argument(s, node.args[i], param)
		case param == .Number:
			args[i + 1] = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = method.missing[i]}, span)
		case:
			args[i + 1] = ir.NO_VALUE // a required argument, whose absence check reported
		}
		complete &&= args[i + 1] != ir.NO_VALUE
	}
	if !complete {
		return ir.NO_VALUE
	}
	return ir.emit(
		&s.fb,
		node_type(s, id),
		ir.Call_Runtime{export = method.export, args = args},
		span,
	)
}

// number_args stays quiet about a call with the wrong count: check already reported it.
@(private)
number_args :: proc(s: ^Func_State, node: ast.Call, want: int) -> ([]ir.Value_ID, bool) {
	if len(node.args) != want {
		return nil, false
	}
	args := make([]ir.Value_ID, want, context.temp_allocator)
	for id, i in node.args {
		args[i] = coerce(s, lower_expression(s, id), ir.F64, s.tree.nodes[id].span)
		if args[i] == ir.NO_VALUE {
			return nil, false
		}
	}
	return args, true
}

@(private)
lower_fold :: proc(s: ^Func_State, node: ast.Call, fold: Fold, span: source.Span) -> ir.Value_ID {
	if len(node.args) == 0 {
		return ir.emit(&s.fb, ir.F64, ir.Const_Number{value = fold.empty}, span)
	}
	args, ok := number_args(s, node, len(node.args))
	if !ok {
		return ir.NO_VALUE
	}
	total := args[0]
	for value in args[1:] {
		call := ir.Call_Runtime {
			export = fold.export,
			args   = {total, value},
		}
		total = ir.emit(&s.fb, ir.F64, call, span)
	}
	return total
}

// lower_console has no value to answer, as the lib declares.
@(private)
lower_console :: proc(
	s: ^Func_State,
	node: ast.Call,
	err: bool,
	span: source.Span,
) -> ir.Value_ID {
	// Node evaluates the whole list before it writes anything, so an argument that prints or exits
	// does so ahead of the line and never in the middle of it.
	args := make([]ir.Value_ID, len(node.args) + 1, context.temp_allocator)
	args[0] = ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = err}, span)
	complete := true
	for id, i in node.args {
		args[i + 1] = console_argument(s, id)
		complete = complete && args[i + 1] != ir.NO_VALUE
	}
	// An argument this build cannot compile does not stop the others from being lowered: one pass
	// names every construct a program would have to change, which is what requirements 2.3 asks of
	// the compiler. The call goes only when every argument has a value; one that never comes back,
	// as process.exit() does, leaves no line to write.
	if complete {
		ir.emit(&s.fb, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = args}, span)
	}
	return ir.NO_VALUE
}

// console_argument boxes the argument into the tagged value the runtime takes, so a narrowed read
// stays as it is (lower_raw). An argument typed undefined or null is that constant whatever
// lowering it answered.
@(private)
console_argument :: proc(s: ^Func_State, id: ast.Node_ID) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	value := lower_raw(s, id)
	switch s.typed.node_types[id] {
	case check.UNDEFINED:
		return ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
	case check.NULL:
		return ir.emit(&s.fb, ir.TAGGED, ir.Const_Null{}, span)
	}
	return coerce(s, value, ir.TAGGED, span)
}

// lower_process_exit emits no terminator of its own: the export never returns, and the statement
// that holds the call closes its block with an unreachable terminator.
@(private)
lower_process_exit :: proc(s: ^Func_State, node: ast.Call, span: source.Span) -> ir.Value_ID {
	code := ir.NO_VALUE
	if len(node.args) > 0 {
		code = optional_number(s, node.args[0], 0, span)
		if code == ir.NO_VALUE {
			return ir.NO_VALUE
		}
	} else {
		code = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	}
	call := ir.Call_Runtime {
		export = .Process_Exit,
		args   = {code},
	}
	ir.emit(&s.fb, ir.VOID, call, span)
	return ir.NO_VALUE
}

// lower_is_integer is Number.isInteger: the value equals its own truncation and is finite. The
// second half runs only when the first holds, since an infinity passes the first.
@(private)
lower_is_integer :: proc(s: ^Func_State, node: ast.Call, span: source.Span) -> ir.Value_ID {
	args, ok := number_args(s, node, 1)
	if !ok {
		return ir.NO_VALUE
	}
	x := args[0]

	whole := ir.emit(&s.fb, ir.F64, ir.Intrinsic{op = .Trunc, args = {x}}, span)
	same := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Equal, left = x, right = whole}, span)
	no := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)

	finite := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	rejected := here(s)
	branch := ir.Branch {
		condition  = same,
		then_block = finite,
		else_block = join,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, finite)
	size := ir.emit(&s.fb, ir.F64, ir.Intrinsic{op = .Abs, args = {x}}, span)
	edge := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = INFINITY}, span)
	bounded := ir.emit(
		&s.fb,
		ir.BOOL,
		ir.Compare{op = .Not_Equal, left = size, right = edge},
		span,
	)
	accepted := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	return join_values(s, join, {rejected, accepted}, {no, bounded}, ir.BOOL, span)
}

// lower_sign is Math.sign: 1, -1, or the value itself, which keeps a negative zero and a NaN as
// they are.
@(private)
lower_sign :: proc(s: ^Func_State, node: ast.Call, span: source.Span) -> ir.Value_ID {
	args, ok := number_args(s, node, 1)
	if !ok {
		return ir.NO_VALUE
	}
	x := args[0]

	above := ir.add_block(&s.fb)
	below_test := ir.add_block(&s.fb)
	below := ir.add_block(&s.fb)
	neither := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)

	zero := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	high := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Greater, left = x, right = zero}, span)
	first := ir.Branch {
		condition  = high,
		then_block = above,
		else_block = below_test,
	}
	ir.emit(&s.fb, ir.VOID, first, span)

	ir.use_block(&s.fb, above)
	one := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 1}, span)
	positive := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	ir.use_block(&s.fb, below_test)
	low := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Less, left = x, right = zero}, span)
	second := ir.Branch {
		condition  = low,
		then_block = below,
		else_block = neither,
	}
	ir.emit(&s.fb, ir.VOID, second, span)

	ir.use_block(&s.fb, below)
	minus := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = -1}, span)
	negative := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	ir.use_block(&s.fb, neither)
	zero_or_nan := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	return join_values(s, join, {positive, negative, zero_or_nan}, {one, minus, x}, ir.F64, span)
}
