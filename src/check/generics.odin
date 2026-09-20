package check

import "../ast"

/*
Generic signatures of the built-in types, which requirements 2.2 gives v1 and keeps generics of
one's own out of until v2. Only the lib file declares a type parameter, so only its signatures hold
a Type_Var, and there are two kinds of them:

  - `interface Array<T>`, whose parameter is settled before anything asks for a member: T[] knows
    its element type, and interface_type reads the members with T standing for it.
  - `map<U>` and `reduce<U>`, whose parameter is settled by the call. That is what this file does.

A call takes the first signature whose arity fits, works the type variables out from the arguments,
and records what it settled on in Typed_File.node_signatures, so lower reads the answer instead of
working it out again.
*/

// Subst is what a call has worked out about the type variables of the signature it chose.
@(private)
Subst :: map[Type_ID]Type_ID

// substitute is a type with every type variable the call has bound replaced by what it stands for.
// A variable nothing has bound is left alone, which is how what one argument settled survives into
// the next. A signature loses the type parameters that were bound, because it is no longer generic.
@(private)
substitute :: proc(c: ^Checker, type: Type_ID, subst: Subst) -> Type_ID {
	if len(subst) == 0 {
		return type
	}

	switch v in c.table.types[type] {
	case Basic_Kind, Literal:
		return type
	case Type_Var:
		bound, found := subst[type]
		return bound if found else type
	case Array:
		return array_type(&c.table, substitute(c, v.element, subst))
	case Union:
		members := make([dynamic]Type_ID, 0, len(v.members), context.temp_allocator)
		for member in v.members {
			append(&members, substitute(c, member, subst))
		}
		return union_type(&c.table, members[:])
	case Overload:
		signatures := make([dynamic]Type_ID, 0, len(v.signatures), context.temp_allocator)
		for signature in v.signatures {
			append(&signatures, substitute(c, signature, subst))
		}
		return overload_type(&c.table, signatures[:])
	case Function:
		params := make([]Param, len(v.params), context.temp_allocator)
		for param, i in v.params {
			params[i] = {
				name = param.name,
				type = substitute(c, param.type, subst),
			}
		}
		free := make([dynamic]Type_ID, 0, len(v.type_params), context.temp_allocator)
		for type_param in v.type_params {
			if _, bound := subst[type_param]; !bound {
				append(&free, type_param)
			}
		}
		result := substitute(c, v.result, subst)
		return function_type(&c.table, params, result, v.required, v.variadic, free[:])
	case Object:
		if v.decl != NO_DECL {
			// A named object would have to be instantiated again from its declaration. No lib
			// signature puts a type variable inside one: `Array<U>` is the array type itself, and
			// nothing else in the lib file is generic.
			return type
		}
		fields := make([]Field, len(v.fields), context.temp_allocator)
		for field, i in v.fields {
			fields[i] = field
			fields[i].type = substitute(c, field.type, subst)
		}
		return plain_object_type(&c.table, fields)
	}
	return type
}

// unify binds the type variables of a parameter to whatever the argument put in their place. It is a
// plain walk down the two types together: a free variable takes the argument, and everything else
// only has to line up for the walk to go on, because fits is what judges the argument afterwards.
//
// A variable takes the widened argument type, as tsc does: `reduce(f, 0)` works `U` out as `number`
// and not as the literal type `0`, which the callback would then be unable to return.
@(private)
unify :: proc(c: ^Checker, param, argument: Type_ID, subst: ^Subst) {
	if param == argument || argument == ERROR {
		return
	}

	#partial switch left in c.table.types[param] {
	case Type_Var:
		if _, bound := subst[param]; !bound {
			subst[param] = widen(&c.table, argument)
		}
	case Array:
		if right, is_array := c.table.types[argument].(Array); is_array {
			unify(c, left.element, right.element, subst)
		}
	case Function:
		right, is_function := c.table.types[argument].(Function)
		if !is_function {
			return
		}
		shared := min(len(left.params), len(right.params))
		for i in 0 ..< shared {
			unify(c, left.params[i].type, right.params[i].type, subst)
		}
		unify(c, left.result, right.result, subst)
	case Object:
		right, is_object := c.table.types[argument].(Object)
		if !is_object {
			return
		}
		for field in left.fields {
			if other, found := find_field(right.fields, field.name); found {
				unify(c, field.type, other.type, subst)
			}
		}
	}
}

// check_signature_call checks the arguments of a call against one signature and works out its type
// variables while it is there.
//
// The arguments that already carry a type go first, so `reduce(f, 0)` knows `U` from the initial
// value before it reads the arrow. The arrows whose parameters have no annotation go second: by then
// every parameter type the call can work out is known, so the arrow gets its parameters, and what
// its body gives binds whatever is still free. That is how `map<U>` reads `U` out of `x => x * 2`.
@(private)
check_signature_call :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Call,
	signature: Type_ID,
) -> Type_ID {
	function := c.table.types[signature].(Function)
	subst := make(Subst, context.temp_allocator)
	defer delete(subst)

	arguments := make([]Type_ID, len(node.args), context.temp_allocator)
	for open in ([2]bool{false, true}) {
		for argument, i in node.args {
			if is_open_arrow(c, argument) != open {
				continue
			}
			parameter := substitute(c, parameter_at(c, function, i), subst)
			arguments[i] = check_expression(c, argument, parameter)
			unify(c, parameter, arguments[i], &subst)
		}
	}

	// A variable no argument reached takes the error type, so that what follows reports the argument
	// it could not place and not every use of the result. No lib signature can reach this today.
	for type_param in function.type_params {
		if _, bound := subst[type_param]; !bound {
			subst[type_param] = ERROR
		}
	}

	for argument, i in node.args {
		parameter := substitute(c, parameter_at(c, function, i), subst)
		if !fits(c, arguments[i], parameter) {
			report_assign_failure(c, span_of(c, argument), arguments[i], parameter)
		}
	}

	instantiated := substitute(c, signature, subst)
	set_signature(c, id, instantiated)
	return c.table.types[instantiated].(Function).result
}

// is_open_arrow reports whether an argument is an arrow still waiting for its parameter types.
@(private)
is_open_arrow :: proc(c: ^Checker, id: ast.Node_ID) -> bool {
	arrow, is_arrow := c.at.tree.nodes[id].variant.(ast.Arrow)
	if !is_arrow {
		return false
	}
	for param in arrow.params {
		if c.at.tree.nodes[param].variant.(ast.Param).type == ast.NO_NODE {
			return true
		}
	}
	return false
}
