package lower

import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../source"

/*
Which functions are closures, what each one captures, and how it holds it. Worked out once per file,
before the first function is declared, from bind's captures and the facts check recorded.

An arrow handed straight to map, filter, forEach or reduce is inlined where it is called
(arrays.odin) and is no closure: what it captures stays a local of the function around it. Every
other arrow, and every function declaration with a body, is a closure. Its captures are bind's,
which pass through every function in between; a recursive nested function lists itself.

A nested declaration whose captures are only declarations it may call directly needs no environment,
and a call of it by name stays a direct call. That is a greatest fixpoint: two nested functions that
call only each other both stay direct. A declaration that is read as a value, not only called, still
needs a closure value of its own, since Node gives it an identity.

The environment of a closure holds its captures, less the declarations it calls directly, in bind's
order. Each is a copy of the value, or a box, a heap cell of one slot the closure shares with the
function around it, where a copy could go stale: the variable is assigned somewhere, or a closure may
run before the declaration has given the variable its value, which is what a hoisted declaration
does with a `const` below it. Nothing else is boxed: a variable only an inlined arrow captures stays
a plain local.
*/

File_Closures :: struct {
	// The closures of the file in walk order: every declaration with a body and every arrow that is
	// not inlined.
	functions:  []ast.Node_ID,
	inlined:    []bool, // by ast.Node_ID: an arrow inlined into an array method
	env_free:   []bool, // by ast.Node_ID of a closure: it takes no environment
	env:        [][]bind.Symbol_ID, // by ast.Node_ID of a closure: its environment, in bind's order
	names:      []string, // by ast.Node_ID of a closure: the name its value prints with
	value_used: []bool, // by bind.Symbol_ID of a nested declaration: read as a value
	boxed:      []bool, // by bind.Symbol_ID: the variable lives in a box
}

// analyze_closures reads the file's check facts, so it runs on a file that runs.
@(private)
analyze_closures :: proc(low: ^Lowering, file: source.File_ID) -> File_Closures {
	tree := &low.prog.trees[file]
	bound := &low.prog.bound[file]
	nodes := len(tree.nodes)
	out := File_Closures {
		inlined    = make([]bool, nodes, context.temp_allocator),
		env_free   = make([]bool, nodes, context.temp_allocator),
		env        = make([][]bind.Symbol_ID, nodes, context.temp_allocator),
		names      = make([]string, nodes, context.temp_allocator),
		value_used = make([]bool, len(bound.symbols), context.temp_allocator),
		boxed      = make([]bool, len(bound.symbols), context.temp_allocator),
	}
	find_uses(low, file, &out)

	functions := make([dynamic]ast.Node_ID, 0, 16, context.temp_allocator)
	stack := make([dynamic]ast.Node_ID, 0, 64, context.temp_allocator)
	append(&stack, ast.ROOT)
	for id in ast.walk(tree.nodes, &stack) {
		#partial switch v in tree.nodes[id].variant {
		case ast.Function_Decl:
			if v.body != ast.NO_NODE {
				append(&functions, id)
			}
		case ast.Arrow:
			if !out.inlined[id] {
				append(&functions, id)
			}
		}
	}
	out.functions = functions[:]

	for id in out.functions {
		out.env_free[id] = true
	}
	for changed := true; changed; {
		changed = false
		for id in out.functions {
			if !out.env_free[id] {
				continue
			}
			for symbol in captures_of(bound, id) {
				if !called_directly(bound, &out, symbol) {
					out.env_free[id] = false
					changed = true
					break
				}
			}
		}
	}

	for id in out.functions {
		env := make([dynamic]bind.Symbol_ID, 0, 4, context.temp_allocator)
		for symbol in captures_of(bound, id) {
			if !called_directly(bound, &out, symbol) {
				append(&env, symbol)
			}
		}
		out.env[id] = env[:]
		for symbol in env {
			out.boxed[symbol] ||= needs_box(tree, bound, id, symbol)
		}
	}
	return out
}

// find_uses marks the inlined arrows, names the arrows Node names, and finds the nested
// declarations read as a value: named anywhere but where a call names what it calls, in front of
// an inlined method (which calls it directly), or under `typeof`.
@(private)
find_uses :: proc(low: ^Lowering, file: source.File_ID, out: ^File_Closures) {
	tree := &low.prog.trees[file]
	bound := &low.prog.bound[file]
	called := make([]bool, len(tree.nodes), context.temp_allocator)

	for node, i in tree.nodes {
		id := ast.Node_ID(i)
		#partial switch v in node.variant {
		case ast.Call:
			called[v.callee] = true
			if len(v.args) > 0 && is_inlined_call(low, file, v) {
				#partial switch _ in tree.nodes[v.args[0]].variant {
				case ast.Arrow:
					out.inlined[v.args[0]] = true
				case ast.Ident:
					called[v.args[0]] = true
				}
			}
		case ast.Unary:
			if v.op == .Typeof {
				called[v.operand] = true
			}
		case ast.Function_Decl:
			out.names[id] = v.name.text
		case ast.Declarator:
			name_arrow(tree, out, v.init, v.name.text)
		case ast.Property:
			name_arrow(tree, out, v.value, v.name.text)
		case ast.Assign:
			if target, is_ident := tree.nodes[v.target].variant.(ast.Ident); is_ident {
				if v.op == .Assign {
					name_arrow(tree, out, v.value, target.name)
				}
			}
		}
	}

	for node, i in tree.nodes {
		if _, is_ident := node.variant.(ast.Ident); !is_ident || called[i] {
			continue
		}
		symbol := bound.node_symbols[i]
		entry := bound.symbols[symbol]
		if symbol != bind.NO_SYMBOL &&
		   entry.kind == .Function &&
		   entry.scope != bind.MODULE_SCOPE {
			out.value_used[symbol] = true
		}
	}
}

// is_inlined_call is the condition lower_strategy reaches map, filter, forEach and reduce by: a
// method of the lib named on an array, whose row is one of the four loops lower builds.
@(private)
is_inlined_call :: proc(low: ^Lowering, file: source.File_ID, call: ast.Call) -> bool {
	tree := &low.prog.trees[file]
	typed := low.facts[file].typed
	member, is_member := tree.nodes[call.callee].variant.(ast.Member)
	if !is_member || typed.node_symbols[call.callee].symbol != bind.NO_SYMBOL {
		return false
	}
	if _, is_array := low.facts[file].result.types[typed.node_types[member.object]].(check.Array);
	   !is_array {
		return false
	}
	strategy, _ := lib_strategy(.Instance, "Array", member.name.text)
	builtin, is_builtin := strategy.(Builtin)
	if !is_builtin {
		return false
	}
	#partial switch builtin {
	case .Array_Map, .Array_Filter, .Array_For_Each, .Array_Reduce:
		return true
	}
	return false
}

// name_arrow gives an arrow the name ECMAScript's NamedEvaluation gives it: that of the binding,
// the variable or the property it is directly the value of, `as` and `!` apart.
@(private)
name_arrow :: proc(tree: ^ast.File_AST, out: ^File_Closures, value: ast.Node_ID, name: string) {
	value := value
	for value != ast.NO_NODE {
		#partial switch v in tree.nodes[value].variant {
		case ast.As:
			value = v.expr
			continue
		case ast.Non_Null:
			value = v.expr
			continue
		case ast.Arrow:
			out.names[value] = name
		}
		return
	}
}

@(private)
captures_of :: proc(bound: ^bind.Bound_File, function: ast.Node_ID) -> []bind.Symbol_ID {
	return bound.scopes[bound.node_scopes[function]].captures
}

// called_directly says whether a capture is a nested declaration every use calls by name: then it
// takes no slot of an environment.
@(private)
called_directly :: proc(
	bound: ^bind.Bound_File,
	out: ^File_Closures,
	symbol: bind.Symbol_ID,
) -> bool {
	entry := bound.symbols[symbol]
	return entry.kind == .Function && out.env_free[entry.declaration] && !out.value_used[symbol]
}

// needs_box says whether a copy of the variable, taken when the closure is made, could differ from
// the variable when the closure reads it. A parameter and a for...of variable have their value
// before any closure inside them is made, so only an assignment can change them.
@(private)
needs_box :: proc(
	tree: ^ast.File_AST,
	bound: ^bind.Bound_File,
	closure: ast.Node_ID,
	symbol: bind.Symbol_ID,
) -> bool {
	entry := bound.symbols[symbol]
	if .Assigned in entry.flags {
		return true
	}
	made := creation_point(tree, bound, closure)
	#partial switch entry.kind {
	case .Function:
		// Both are made on entry to their block, in source order, and each needs the other's value
		// in its environment.
		_, hoisted := tree.nodes[closure].variant.(ast.Function_Decl)
		return hoisted && bound.symbols[bound.node_symbols[closure]].scope == entry.scope
	case .Let, .Const:
		return tree.nodes[entry.declaration].span.end > made
	}
	return false
}

// creation_point is where a closure is made: an arrow where it stands, a declaration where the
// block that holds it opens, since it is hoisted.
@(private)
creation_point :: proc(tree: ^ast.File_AST, bound: ^bind.Bound_File, closure: ast.Node_ID) -> i32 {
	if _, is_arrow := tree.nodes[closure].variant.(ast.Arrow); is_arrow {
		return tree.nodes[closure].span.start
	}
	scope := bound.symbols[bound.node_symbols[closure]].scope
	return tree.nodes[bound.scopes[scope].node].span.start
}

// Making closures.

// make_closure makes a new closure of a function this file declares: its environment first, a
// copy of each value it captures or the box that value lives in, then the cell. A capture with no
// value was refused where it is declared, and the closure is poison without another word.
@(private)
make_closure :: proc(s: ^Func_State, node: ast.Node_ID, span: source.Span) -> ir.Value_ID {
	func, declared := s.low.funcs[{s.file, node}]
	if !declared {
		return ir.NO_VALUE
	}
	describe_closure(s.low, s.file, node, func)
	layout := s.low.builder.funcs[func].env
	if layout == ir.NO_LAYOUT {
		return ir.emit(&s.fb, ir.CLOSURE, ir.Make_Closure{func = func, env = ir.NO_VALUE}, span)
	}
	symbols := s.low.closures[s.file].env[node]
	for symbol in symbols {
		if local_value(s, symbol) == ir.NO_VALUE {
			return ir.NO_VALUE
		}
	}
	env := ir.emit(&s.fb, ir.ref(layout), ir.Alloc{layout = layout}, span)
	for symbol, i in symbols {
		store_slot(s, env, i32(i), local_value(s, symbol), span)
	}
	return ir.emit(&s.fb, ir.CLOSURE, ir.Make_Closure{func = func, env = env}, span)
}

// describe_closure records what the console prints of the function as a value: the name Node gives
// it, how many parameters it declares, and whether it has a prototype, which a declaration has and
// an arrow does not.
@(private)
describe_closure :: proc(
	low: ^Lowering,
	file: source.File_ID,
	node: ast.Node_ID,
	func: ir.Func_ID,
) {
	if low.builder.funcs[func].info != nil {
		return
	}
	params: []ast.Node_ID
	prototype := false
	#partial switch v in low.prog.trees[file].nodes[node].variant {
	case ast.Function_Decl:
		params, prototype = v.params, true
	case ast.Arrow:
		params = v.params
	}
	ir.describe_func(&low.builder, func, low.closures[file].names[node], len(params), prototype)
}
