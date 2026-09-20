package check

import "../ast"
import "../bind"
import "../program"

// Type syntax.

// resolve_type is the type a type slot names. A slot a later task owns — a qualified name, a name
// imported from another module, a type parameter outside the lib file — answers with the error type
// and says nothing.
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

// resolve_type_params is the type variables a generic signature has to work out at a call. Only the
// lib file declares any: a type parameter of a user file answers with the error type, and a
// signature that holds none is the ordinary case.
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

// resolve_params reads the parameters of a function, an arrow or a function type. required counts
// the parameters a call has to supply, which is the run of required ones at the front: a required
// parameter behind an optional one is a signature tsc rejects, and tsnc takes its input from tsc.
//
// contextual is the parameter list of the signature an arrow is going into, and gives a parameter
// with no annotation its type. Everywhere else it is empty, and a parameter with no annotation is a
// name nothing can check.
@(private)
resolve_params :: proc(
	c: ^Checker,
	ids: []ast.Node_ID,
	contextual: []Param = nil,
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
		case i < len(contextual):
			type = contextual[i].type
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

// resolve_name is the symbol a name refers to. bind answers for a name the file declares; a name it
// does not is a name of the lib module, which every file sees, or nothing at all.
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

// type_of_symbol is the type of a declared name, worked out the first time anything asks and kept
// afterwards. A declaration that needs its own type to answer has no answer at all, and the
// annotation has to say instead.
@(private)
type_of_symbol :: proc(c: ^Checker, ref: Symbol_Ref) -> Type_ID {
	if ref.symbol == bind.NO_SYMBOL {
		return ERROR
	}
	if cached, found := c.symbol_types[ref]; found {
		return cached
	}

	symbol := c.program.bound[ref.file].symbols[ref.symbol]
	if ref in c.resolving {
		report(c, .Recursive_Return_Type, symbol.name.span, symbol.name.text)
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

// declared_type works out the type of a symbol from the node that declares it.
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
	// the path that answers for them. An imported name is T3.5.
	return ERROR
}

// declarator_type is the type of one `let` or `const` binding, and it checks the initializer while
// it is here. The walk over the statements comes through here too, so this happens exactly once.
@(private)
declarator_type :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Declarator,
	kind: bind.Symbol_Kind,
) -> Type_ID {
	if node.type != ast.NO_NODE {
		declared := resolve_type(c, node.type)
		if node.init != ast.NO_NODE {
			value := check_expression(c, node.init, declared)
			if !fits(c, value, declared) {
				report_assign_failure(c, span_of(c, node.init), value, declared)
			}
		}
		return set_type(c, id, declared)
	}

	if node.init == ast.NO_NODE {
		// Requirements 5 takes a variable's type from its initializer, and there is none.
		report(c, .Missing_Annotation, node.name.span, node.name.text)
		return set_type(c, id, ERROR)
	}

	value := check_expression(c, node.init)
	// A `const` keeps the literal type of its value, because the binding never takes another one.
	// A `let` widens, because it can.
	return set_type(c, id, value if kind == .Const else widen(&c.table, value))
}

// function_decl_type is the type of a `function` declaration, and it reads the body while it is
// here. An annotated result is recorded before the body, so that a call to the function inside its
// own body finds it. An inferred one is not known until the body has been read, so a call to itself
// there has nothing to find, which is what Recursive_Return_Type says.
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
		return type
	}

	returns := make([dynamic]Type_ID, 0, 4, context.temp_allocator)
	check_body(c, node.body, ERROR, &returns)
	result := inferred_result(c, node.body, returns[:])
	return set_type(c, id, function_type(&c.table, params, result, required, variadic))
}

// inferred_result is the result of a function with no annotation: the union of what its `return`
// statements gave, widened, because what a call hands back is not the one literal the body happened
// to write. A bare `return` gives nothing to the union, as in tsc, so a body that returns no value
// at all gives `void`.
//
// A body that can also run off its end gives `undefined` besides, which is what tsc infers for
// `function f(c: boolean) { if (c) return 1; }`.
@(private)
inferred_result :: proc(c: ^Checker, body: ast.Node_ID, returns: []Type_ID) -> Type_ID {
	if len(returns) == 0 {
		return VOID
	}

	widened := make([dynamic]Type_ID, 0, len(returns) + 1, context.temp_allocator)
	for type in returns {
		append(&widened, widen(&c.table, type))
	}
	if falls_through(c, body) {
		append(&widened, UNDEFINED)
	}
	return union_type(&c.table, widened[:])
}

// falls_through reports whether control can reach the end of a body. bind already knows: it leaves
// the flow after a `return` unreachable, and records the flow left at the end of the body block. An
// arrow written without braces is its own value and always produces one.
@(private)
falls_through :: proc(c: ^Checker, body: ast.Node_ID) -> bool {
	if body == ast.NO_NODE {
		return false
	}
	if _, is_block := c.at.tree.nodes[body].variant.(ast.Block); !is_block {
		return false
	}
	return c.at.bound.node_flow[body] != bind.UNREACHABLE
}

// check_body reads the body of a function or an arrow. returns is non-nil while the result is being
// inferred, and collects what each `return` gave; otherwise result is the declared one and every
// `return` is checked against it.
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
