package lower

import "../abi"
import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../program"
import "../source"

/*
Calls, and with them the whole of the standard library. A call is one of three things: a function of
the program, which resolves statically and becomes a direct call; a name of the lib, which the
strategy table of lib.odin turns into an intrinsic, an operator, a runtime call or a shape built
here; or a function value, which needs the closures of milestone 5.

console.log is the one name whose expansion is worth stating. The compiler knows every argument
statically, so a statement becomes one runtime call per argument with the separators and the line
end written as string constants. Nothing formats a list at run time, and the runtime needs one
export per kind of value rather than one that understands them all. Every argument is evaluated
before the first write, as Node does it.
*/

@(private)
lower_call :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Call) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	if member, is_member := s.tree.nodes[node.callee].variant.(ast.Member); is_member {
		return lower_method_call(s, node, member, span)
	}
	if _, is_ident := s.tree.nodes[node.callee].variant.(ast.Ident); !is_ident {
		return later(s, span, "calling a function value")
	}

	ref := s.typed.node_symbols[node.callee]
	if ref.symbol == bind.NO_SYMBOL {
		return ir.NO_VALUE
	}
	if ref.file == program.LIB {
		name := s.low.prog.bound[program.LIB].symbols[ref.symbol].name.text
		strategy, found := lib_strategy(.Value, name, "")
		if !found {
			return ir.NO_VALUE
		}
		return lower_strategy(s, node, strategy, name, span)
	}

	declared := s.low.prog.bound[ref.file].symbols[ref.symbol]
	if func, is_function := s.low.funcs[{ref.file, declared.declaration}]; is_function {
		return lower_direct_call(s, node, func, span)
	}
	if declared.kind != .Function {
		return later(s, span, "calling a function value")
	}
	// The declaration itself was reported; saying it again at every call helps nobody.
	return ir.NO_VALUE
}

// lower_method_call finds either a name of the lib or a member of an object, which milestone 5
// owns.
@(private)
lower_method_call :: proc(
	s: ^Func_State,
	node: ast.Call,
	member: ast.Member,
	span: source.Span,
) -> ir.Value_ID {
	strategy, found := member_strategy(s, member)
	if !found {
		return ir.NO_VALUE
	}
	return lower_strategy(s, node, strategy, member.name.text, span)
}

// lower_direct_call gives an argument the call leaves out the zero of its parameter, which for an
// optional one is undefined: the parameters of the IR function are the types the body sees.
@(private)
lower_direct_call :: proc(
	s: ^Func_State,
	node: ast.Call,
	func: ir.Func_ID,
	span: source.Span,
) -> ir.Value_ID {
	declared := s.low.builder.funcs[func]
	args := make([]ir.Value_ID, len(declared.params), context.temp_allocator)
	for i in 0 ..< len(declared.params) {
		if i < len(node.args) {
			args[i] = coerce(s, lower_expression(s, node.args[i]), declared.params[i], span)
		} else {
			args[i] = zero_value(s, declared.params[i], span)
		}
		if args[i] == ir.NO_VALUE {
			return ir.NO_VALUE
		}
	}
	return ir.emit(&s.fb, declared.result, ir.Call{func = func, args = args}, span)
}

@(private)
lower_strategy :: proc(
	s: ^Func_State,
	node: ast.Call,
	strategy: Strategy,
	name: string,
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
		exports := abi.RUNTIME_EXPORTS
		args, ok := number_args(s, node, len(exports[v.export].params))
		if !ok {
			return ir.NO_VALUE
		}
		return ir.emit(&s.fb, ir.F64, ir.Call_Runtime{export = v.export, args = args}, span)
	case Fold:
		return lower_fold(s, node, v, span)
	case Builtin:
		switch v {
		case .Console_Log:
			return lower_console(s, node, false, span)
		case .Console_Error:
			return lower_console(s, node, true, span)
		case .Process_Exit:
			return lower_process_exit(s, node, span)
		case .Number_Is_Integer:
			return lower_is_integer(s, node, span)
		case .Math_Sign:
			return lower_sign(s, node, span)
		}
	}
	return later(s, span, name)
}

// number_args stays quiet about a call with the wrong count: check already reported it.
@(private)
number_args :: proc(s: ^Func_State, node: ast.Call, want: int) -> ([]ir.Value_ID, bool) {
	if len(node.args) != want {
		return nil, false
	}
	args := make([]ir.Value_ID, want, context.temp_allocator)
	for id, i in node.args {
		args[i] = lower_expression(s, id)
		if args[i] == ir.NO_VALUE {
			return nil, false
		}
		if value_type(s, args[i]) != ir.F64 {
			operand_not_lowered(s, args[i], s.tree.nodes[id].span)
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
	values := make([]ir.Value_ID, len(node.args), context.temp_allocator)
	for id, i in node.args {
		values[i] = lower_expression(s, id)
	}

	// An argument this build cannot print does not stop the rest: one pass names every construct a
	// program would have to change, which is what requirements 2.3 asks of the compiler.
	for id, i in node.args {
		if i > 0 {
			write_text(s, err, " ", span)
		}
		write_argument(s, err, id, values[i])
	}
	write_text(s, err, "\n", span)
	return ir.NO_VALUE
}

// write_argument runs none of the program's code: the caller evaluated the argument already.
@(private)
write_argument :: proc(s: ^Func_State, err: bool, id: ast.Node_ID, value: ir.Value_ID) {
	span := s.tree.nodes[id].span
	type := s.typed.node_types[id]
	if type == check.UNDEFINED || type == check.NULL {
		// Both are a word, and both are the same word at every call site.
		write_text(s, err, "undefined" if type == check.UNDEFINED else "null", span)
		return
	}

	if value == ir.NO_VALUE {
		return
	}
	export: abi.Runtime_Proc
	#partial switch value_type(s, value).kind {
	case .F64:
		export = .Console_Number
	case .Bool:
		export = .Console_Boolean
	case .Str:
		export = .Console_String
	case .Tagged:
		later(s, span, "printing a union")
		return
	case:
		later(s, span, "printing a value of this type")
		return
	}
	stream := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = err}, span)
	ir.emit(&s.fb, ir.VOID, ir.Call_Runtime{export = export, args = {stream, value}}, span)
}

@(private)
write_text :: proc(s: ^Func_State, err: bool, text: string, span: source.Span) {
	stream := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = err}, span)
	pooled := ir.intern_string(&s.low.builder, text)
	value := ir.emit(&s.fb, ir.STR, ir.Const_String{text = pooled}, span)
	call := ir.Call_Runtime {
		export = .Console_String,
		args   = {stream, value},
	}
	ir.emit(&s.fb, ir.VOID, call, span)
}

// lower_process_exit emits no terminator of its own: the export never returns, and the statement
// that holds the call closes its block with an unreachable terminator.
@(private)
lower_process_exit :: proc(s: ^Func_State, node: ast.Call, span: source.Span) -> ir.Value_ID {
	code := ir.NO_VALUE
	if len(node.args) > 0 {
		code = lower_expression(s, node.args[0])
		if code == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		if value_type(s, code) != ir.F64 {
			return operand_not_lowered(s, code, span)
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
