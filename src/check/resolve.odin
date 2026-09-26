package check

import "../ast"
import "../bind"
import "../diag"
import "../program"

// Type syntax.

// resolve_type answers with the error type for a slot the rules could not read: it is assignable in
// both directions, so one message stays one message.
@(private)
resolve_type :: proc(c: ^Checker, id: ast.Node_ID) -> Type_ID {
	if id == ast.NO_NODE {
		return ERROR
	}
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Keyword_Type:
		return set_type(c, id, KEYWORD_TYPES[v.keyword])
	case ast.Literal_Type:
		return set_type(c, id, literal_type(&c.table, v.value))
	case ast.Union_Type:
		members := make([dynamic]Type_ID, 0, len(v.members), context.temp_allocator)
		for member in v.members {
			append(&members, resolve_type(c, member))
		}
		return set_type(c, id, union_type(&c.table, members[:]))
	case ast.Function_Type:
		check_signature_type_params(c, v.type_params)
		type_params := resolve_type_params(c, v.type_params)
		params, required, variadic := resolve_params(c, v.params)
		result := resolve_type(c, v.return_type)
		type := function_type(&c.table, params, result, required, variadic, type_params)
		return set_type(c, id, type)
	case ast.Array_Type:
		return set_type(c, id, array_type(&c.table, resolve_type(c, v.element)))
	case ast.Object_Type:
		return set_type(c, id, plain_object_type(&c.table, object_fields(c, v.members)))
	case ast.Type_Ref:
		return set_type(c, id, type_ref_type(c, id, v))
	}
	return set_type(c, id, ERROR)
}

// resolve_type_params answers only in the lib file, which alone declares type variables: a type
// parameter of a user file answers with the error type, and a signature that holds none is the
// ordinary case.
@(private)
resolve_type_params :: proc(c: ^Checker, ids: []ast.Node_ID) -> []Type_ID {
	if len(ids) == 0 || c.at.file != program.LIB {
		return nil
	}
	out := make([dynamic]Type_ID, 0, len(ids), context.temp_allocator)
	for id in ids {
		type_param := c.at.tree.nodes[id].variant.(ast.Type_Param)
		decl := Decl_Ref {
			file = c.at.file,
			node = id,
		}
		append(&out, type_var_type(&c.table, type_param.name.text, decl))
	}
	return out[:]
}

@(private, rodata)
KEYWORD_TYPES := [ast.Type_Keyword]Type_ID {
	.Number    = NUMBER,
	.String    = STRING,
	.Boolean   = BOOLEAN,
	.Null      = NULL,
	.Undefined = UNDEFINED,
	.Void      = VOID,
	.Any       = ANY,
	.Unknown   = UNKNOWN,
	.Never     = NEVER,
}

// resolve_params counts in required the parameters a call has to supply, which is the run of
// required ones at the front: a required parameter behind an optional one is a signature tsc
// rejects, and tsnc takes its input from tsc.
//
// contextual is the signature an arrow is going into, and gives a parameter with no annotation its
// type. parameter_at answers for the position, so one landing on an optional parameter is
// `T | undefined` and one landing on a rest parameter is the element type: what a call can really
// leave there. Everywhere else there is no signature, and a parameter with no annotation is a name
// nothing can check.
@(private)
resolve_params :: proc(
	c: ^Checker,
	ids: []ast.Node_ID,
	contextual: Maybe(Function) = nil,
) -> (
	params: []Param,
	required: int,
	variadic: bool,
) {
	out := make([dynamic]Param, 0, len(ids), context.temp_allocator)
	for id, i in ids {
		param := c.at.tree.nodes[id].variant.(ast.Param)
		type := ERROR
		switch {
		case param.type != ast.NO_NODE:
			type = resolve_type(c, param.type)
		case contextual != nil:
			// Past the end of a signature with no rest parameter there is no context at all.
			type = parameter_at(c, contextual.?, i)
			if type == ERROR {
				report(c, .Missing_Annotation, param.name.span, param.name.text)
			}
		case:
			report(c, .Missing_Annotation, param.name.span, param.name.text)
		}

		// The body sees what a call can actually leave there, while the signature keeps the type as
		// it was written: TypeScript prints `b?: string`, not `b?: string | undefined`.
		inside := type
		switch param.kind {
		case .Required:
			if required == i {
				required += 1
			}
		case .Optional:
			inside = union_of(c, type, UNDEFINED)
		case .Rest:
			variadic = true
		}

		set_type(c, id, inside)
		append(&out, Param{name = param.name.text, type = type})
	}
	return out[:], required, variadic
}

// Names.

// resolve_name stays inside this file: bind answers for a name the file declares, an import
// included; a name it does not is a name of the lib module, which every file sees, or nothing at
// all. Following an import to the module it came from is modules.odin's job.
@(private)
resolve_name :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	name: string,
	meaning: bind.Meaning,
) -> Symbol_Ref {
	if symbol := c.at.bound.node_symbols[id]; symbol != bind.NO_SYMBOL {
		return {file = c.at.file, symbol = symbol}
	}
	lib := c.program.bound[program.LIB]
	if symbol := bind.lookup(lib, bind.MODULE_SCOPE, name, meaning); symbol != bind.NO_SYMBOL {
		return {file = program.LIB, symbol = symbol}
	}
	return {}
}

// type_of_symbol has no answer for a declaration that needs its own type to answer, and the
// annotation has to say instead.
//
// A name read inside a function body is a different matter: the body runs later, so the declaration
// may well have its type by then. The node holds it as soon as it is known without the body, which
// is what makes a recursive arrow with a return type work.
@(private)
type_of_symbol :: proc(c: ^Checker, ref: Symbol_Ref) -> Type_ID {
	if ref.symbol == bind.NO_SYMBOL {
		return ERROR
	}
	if cached, found := c.symbol_types[ref]; found {
		return cached
	}

	symbol := c.program.bound[ref.file].symbols[ref.symbol]
	if _, found := c.resolving[ref]; found {
		// Outside a body only an annotation records the type this early, and then a read of the
		// name inside its own initializer is a use before the declaration (check_declared).
		if type := recorded_declaration(c, ref, symbol); type != ERROR {
			return type
		}
		report(c, recursion_code(c, ref, symbol), symbol.name.span, symbol.name.text)
		c.symbol_types[ref] = ERROR
		return ERROR
	}

	c.resolving[ref] = true
	previous := move_to(c, ref.file)
	type := declared_type(c, ref, symbol)
	c.at = previous
	delete_key(&c.resolving, ref)

	// A function whose result is annotated answers before its body is read, so that a call to
	// itself inside that body finds the answer rather than the search still running.
	if cached, found := c.symbol_types[ref]; found {
		return cached
	}
	c.symbol_types[ref] = type
	return type
}

// recorded_declaration is the type the declaring node already holds, while the search for it is
// still running further out. It is there as soon as the type is known without reading a body: an
// annotated declarator, and an arrow whose result is written out.
@(private)
recorded_declaration :: proc(c: ^Checker, ref: Symbol_Ref, symbol: bind.Symbol) -> Type_ID {
	types := c.facts[ref.file].node_types
	if types == nil || symbol.declaration == ast.NO_NODE {
		return ERROR
	}
	return types[symbol.declaration]
}

// recursion_code tells two mistakes apart: a function and an arrow both lack a result the search
// could use, which is what an annotation supplies; any other variable has an initializer that reads
// the name it is defining.
@(private)
recursion_code :: proc(c: ^Checker, ref: Symbol_Ref, symbol: bind.Symbol) -> diag.Code {
	if symbol.kind == .Function {
		return .Recursive_Return_Type
	}
	nodes := c.program.trees[ref.file].nodes
	if declarator, is_declarator := nodes[symbol.declaration].variant.(ast.Declarator);
	   is_declarator {
		if _, is_arrow := nodes[declarator.init].variant.(ast.Arrow); is_arrow {
			return .Recursive_Return_Type
		}
	}
	return .Circular_Initializer
}

@(private)
declared_type :: proc(c: ^Checker, ref: Symbol_Ref, symbol: bind.Symbol) -> Type_ID {
	node := symbol.declaration
	#partial switch v in c.at.tree.nodes[node].variant {
	case ast.Declarator:
		return declarator_type(c, node, v, symbol.kind)
	case ast.Function_Decl:
		return function_decl_type(c, ref, node, v)
	case ast.Param:
		// A parameter takes its type when its function is typed, which always happens before
		// anything in the body can name it.
		return c.at.node_types == nil ? ERROR : c.at.node_types[node]
	}
	// An interface, a type alias and a type parameter are types and not values, and named_type is
	// the path that answers for them. An alias does not arrive either: imported_name follows it to
	// the declaration behind it and asks about that.
	return ERROR
}

// declarator_type checks the initializer while it is here. The walk over the statements comes
// through here too, so this happens exactly once.
//
// The node holds its type before the initializer is read wherever the type is known without it, so
// that a name used inside its own initializer's body finds the answer rather than the search still
// running.
@(private)
declarator_type :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Declarator,
	kind: bind.Symbol_Kind,
) -> Type_ID {
	if node.type != ast.NO_NODE {
		declared := resolve_type(c, node.type)
		set_type(c, id, declared)
		if node.init != ast.NO_NODE {
			value := check_expression(c, node.init, declared)
			if !fits(c, value, declared) {
				report_assign_failure(c, span_of(c, node.init), value, declared)
			}
		} else if kind == .Let && exported(c, id) && !fits(c, UNDEFINED, declared) {
			// No walk sees across modules, so a write in another one cannot be looked for at all.
			report(c, .Used_Before_Assigned, node.name.span, node.name.text)
		}
		return declared
	}

	if node.init == ast.NO_NODE {
		// Requirements 5 takes a variable's type from its initializer, and there is none.
		report(c, .Missing_Annotation, node.name.span, node.name.text)
		return set_type(c, id, ERROR)
	}

	if arrow, is_arrow := c.at.tree.nodes[node.init].variant.(ast.Arrow); is_arrow {
		if arrow.return_type != ast.NO_NODE && !is_open_arrow(c, node.init) {
			// The signature is known without reading the body, so check_arrow records it on this
			// declaration before it goes in. That is what lets an arrow call itself.
			type := check_arrow(c, arrow, ERROR, id)
			set_type(c, node.init, type)
			return set_type(c, id, type)
		}
	}

	value := check_expression(c, node.init)
	// A `const` keeps the literal type of its value, because the binding never takes another one.
	// A `let` widens, because it can.
	return set_type(c, id, value if kind == .Const else widen(&c.table, value))
}

@(private)
exported :: proc(c: ^Checker, declaration: ast.Node_ID) -> bool {
	symbol := c.at.bound.node_symbols[declaration]
	if symbol == bind.NO_SYMBOL {
		return false
	}
	for export in c.at.bound.exports {
		if export.symbol == symbol {
			return true
		}
	}
	return false
}

// function_decl_type reads the body while it is here. An annotated result is recorded before the
// body, so that a call to the function inside its own body finds it. An inferred one is not known
// until the body has been read, so a call to itself there has nothing to find, which is what
// Recursive_Return_Type says.
@(private)
function_decl_type :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
	id: ast.Node_ID,
	node: ast.Function_Decl,
) -> Type_ID {
	params, required, variadic := resolve_params(c, node.params)

	if node.return_type != ast.NO_NODE {
		result := resolve_type(c, node.return_type)
		type := function_type(&c.table, params, result, required, variadic)
		c.symbol_types[ref] = type
		set_type(c, id, type)
		check_body(c, node.body, result, nil)
		check_result_reached(c, node.body, node.return_type, result)
		return type
	}

	returns := make([dynamic]Type_ID, 0, 4, context.temp_allocator)
	check_body(c, node.body, ERROR, &returns)
	result := inferred_result(c, node.body, returns[:])
	return set_type(c, id, function_type(&c.table, params, result, required, variadic))
}

// check_result_reached lets `void` and `any` take a body that can end without a `return`, and a
// result written `T | undefined` as well; anything else would hand the caller a value that is not
// there.
@(private)
check_result_reached :: proc(
	c: ^Checker,
	body: ast.Node_ID,
	annotation: ast.Node_ID,
	result: Type_ID,
) {
	if !falls_through(c, body) || fits(c, UNDEFINED, result) {
		return
	}
	report(c, .Missing_Return, span_of(c, annotation), text_of(c, result))
}

// inferred_result widens what the `return` statements gave, because what a call hands back is not
// the one literal the body happened to write.
//
// A body whose every `return` is bare gives `void`, as in tsc. One that mixes a bare `return` with
// a `return` of a value gives `undefined` for the bare one, which is what check_return's VOID
// marker says; and a body that can also run off its end gives `undefined` besides, which is what
// tsc infers for `function f(c: boolean) { if (c) return 1; }`.
@(private)
inferred_result :: proc(c: ^Checker, body: ast.Node_ID, returns: []Type_ID) -> Type_ID {
	if len(returns) == 0 || every_return_is_bare(returns) {
		return VOID
	}

	widened := make([dynamic]Type_ID, 0, len(returns) + 1, context.temp_allocator)
	for type in returns {
		append(&widened, UNDEFINED if type == VOID else widen(&c.table, type))
	}
	if falls_through(c, body) {
		append(&widened, UNDEFINED)
	}
	return union_type(&c.table, widened[:])
}

@(private)
every_return_is_bare :: proc(returns: []Type_ID) -> bool {
	for type in returns {
		if type != VOID {
			return false
		}
	}
	return true
}

// falls_through asks the flow graph. The flow at the end of a block is where the paths through it
// join, and a join is a node whether or not anything arrives, so reaches_start walks back from it
// and stops at a `return`, at a call that never returns and at an exhausted `switch`. An arrow
// written without braces is its own value and always produces one.
@(private)
falls_through :: proc(c: ^Checker, body: ast.Node_ID) -> bool {
	if body == ast.NO_NODE {
		return false
	}
	if _, is_block := c.at.tree.nodes[body].variant.(ast.Block); !is_block {
		return false
	}
	return reaches_start(c, c.at.bound.node_flow[body])
}

// check_body takes a non-nil returns while the result is being inferred, and collects in it what
// each `return` gave; otherwise result is the declared one and every `return` is checked against
// it.
@(private)
check_body :: proc(c: ^Checker, body: ast.Node_ID, result: Type_ID, returns: ^[dynamic]Type_ID) {
	if body == ast.NO_NODE {
		return // `declare function` has no body
	}

	previous_result, previous_returns := c.at.result, c.at.returns
	c.at.result, c.at.returns = result, returns
	defer {
		c.at.result = previous_result
		c.at.returns = previous_returns
	}

	if block, is_block := c.at.tree.nodes[body].variant.(ast.Block); is_block {
		check_statements(c, block.statements)
		set_type(c, body, VOID)
		return
	}

	// An arrow with no braces returns the expression it is.
	type := check_expression(c, body, result)
	if returns != nil {
		append(returns, type)
		return
	}
	if !fits(c, type, result) {
		report_assign_failure(c, span_of(c, body), type, result)
	}
}
