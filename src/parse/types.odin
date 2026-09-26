#+private
package parse

import "../ast"
import "../diag"

// parse_type turns a conditional type `A extends B ? C : D` into one Bad node: it is outside the
// subset.
parse_type :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	m := mark(p)
	start := token_start(p)
	type := parse_union_type(p)
	token := peek(p)
	if token.kind != .Extends || token.line_break_before {
		return type
	}
	report_unsupported(p, .Conditional_Types, advance(p).span)
	parse_union_type(p)
	expect(p, .Question)
	parse_type(p)
	expect(p, .Colon)
	parse_type(p)
	return discard(p, m, start)
}

// parse_union_type parses the types around `|` as one flat Union_Type, with an optional leading
// `|`. A union in parentheses stays one member.
parse_union_type :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	accept(p, .Bar)
	member := parse_intersection_type(p)
	if !at(p, .Bar) {
		return member
	}
	first := len(p.scratch)
	append(&p.scratch, member)
	for accept(p, .Bar) {
		append(&p.scratch, parse_intersection_type(p))
	}
	return add_node(p, start, ast.Union_Type{members = finish_list(p, first)})
}

// parse_intersection_type parses a member of a union. An intersection `A & B` is outside the
// subset.
parse_intersection_type :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	type := parse_array_type(p)
	if !at(p, .Amp) {
		return type
	}
	report_unsupported(p, .Intersection_Types, peek(p).span)
	for accept(p, .Amp) {
		parse_array_type(p)
	}
	return discard(p, m, start)
}

// parse_array_type parses `T[]`, `T[][]`. The `[` must be on the line of the type: on the next
// line it starts the next member of an object type. An indexed access `T[K]` is outside the
// subset.
parse_array_type :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	type := parse_primary_type(p)
	for at(p, .Open_Bracket) && !peek(p).line_break_before {
		if peek(p, 1).kind == .Close_Bracket {
			advance(p)
			advance(p)
			type = add_node(p, start, ast.Array_Type{element = type})
			continue
		}
		report_unsupported(p, .Indexed_Access_Types, peek(p).span)
		skip_balanced(p)
		type = discard(p, m, start)
	}
	return type
}

parse_primary_type :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	token := peek(p)
	start := token.span.start
	#partial switch token.kind {
	case .Identifier:
		return parse_named_type(p)
	case .Null:
		advance(p)
		return add_node(p, start, ast.Keyword_Type{keyword = .Null})
	case .Void:
		advance(p)
		return add_node(p, start, ast.Keyword_Type{keyword = .Void})
	case .True, .False:
		advance(p)
		return add_node(p, start, ast.Literal_Type{value = token.kind == .True})
	case .String:
		advance(p)
		return add_node(p, start, ast.Literal_Type{value = token.value.(string)})
	case .Number:
		advance(p)
		return add_node(p, start, ast.Literal_Type{value = token.value.(f64)})
	case .Minus:
		if peek(p, 1).kind == .Number {
			advance(p)
			number := advance(p)
			return add_node(p, start, ast.Literal_Type{value = -number.value.(f64)})
		}
	case .Open_Paren:
		if starts_function_type(p) {
			return parse_function_type(p)
		}
		// Parentheses make no node.
		advance(p)
		type := parse_type(p)
		expect(p, .Close_Paren)
		return type
	case .Less:
		return parse_function_type(p)
	case .Open_Brace:
		return parse_object_type(p)
	case .Open_Bracket:
		return skip_type(p, .Tuple_Types)
	case .No_Substitution_Template, .Template_Head:
		return skip_type(p, .Template_Literal_Types)
	case .Typeof:
		m := mark(p)
		report_unsupported(p, .Typeof_Types, advance(p).span)
		parse_primary_type(p)
		return discard(p, m, start)
	case .This:
		return skip_type(p, .This_Types)
	case .New:
		m := mark(p)
		report_unsupported(p, .Constructor_Types, advance(p).span)
		parse_function_type(p)
		return discard(p, m, start)
	}
	error_expected(p, "a type")
	return add_missing(p)
}

skip_type :: proc(p: ^Parser, construct: diag.Construct) -> ast.Node_ID {
	start := token_start(p)
	report_unsupported(p, construct, peek(p).span)
	#partial switch peek(p).kind {
	case .Open_Bracket, .Template_Head:
		skip_balanced(p)
	case:
		advance(p)
	}
	return add_node(p, start, ast.Bad{})
}

// parse_named_type parses a type that starts with a name: a keyword type such as `number`, or a
// reference `T`, `m.T`, `T<A, B>`.
parse_named_type :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	token := advance(p)
	start := token.span.start
	name := token.value.(string)

	keyword: ast.Type_Keyword
	is_keyword := true
	switch name {
	case "number":
		keyword = .Number
	case "string":
		keyword = .String
	case "boolean":
		keyword = .Boolean
	case "undefined":
		keyword = .Undefined
	case "any":
		keyword = .Any
	case "unknown":
		keyword = .Unknown
	case "never":
		keyword = .Never
	case:
		is_keyword = false
	}
	if is_keyword {
		return add_node(p, start, ast.Keyword_Type{keyword = keyword})
	}

	// Type operators outside the subset, which apply to the type after them.
	operator: diag.Construct
	is_operator := true
	switch name {
	case "keyof":
		operator = .Keyof_Types
	case "readonly":
		operator = .Readonly_Array_Types
	case "unique":
		operator = .Unique_Symbol_Types
	case "infer":
		operator = .Infer_Types
	case:
		is_operator = false
	}
	if is_operator && is_type_operand(peek(p)) {
		report_unsupported(p, operator, token.span)
		parse_array_type(p)
		return discard(p, m, start)
	}
	switch name {
	case "object", "symbol", "bigint":
		report_unsupported(p, .Object_Symbol_Bigint_Types, token.span)
		return add_node(p, start, ast.Bad{})
	case "asserts":
		// `asserts x` or `asserts x is T` in a return type.
		subject := peek(p)
		is_subject := subject.kind == .Identifier || subject.kind == .This
		if is_subject && !subject.line_break_before {
			report_unsupported(p, .Type_Predicates, token.span)
			advance(p)
			if accept_word(p, "is") {
				parse_type(p)
			}
			return discard(p, m, start)
		}
	}

	qualifier: ast.Name
	type_name := name_of(token)
	if accept(p, .Dot) {
		qualifier = type_name
		type_name = parse_type_name(p)
		if at(p, .Dot) {
			report_unsupported(p, .Deep_Qualified_Names, peek(p).span)
			for accept(p, .Dot) {
				parse_member_name(p)
			}
		}
	}
	args: []ast.Node_ID
	if at(p, .Less) && !peek(p).line_break_before {
		args = parse_type_arguments(p)
	}
	type := add_node(p, start, ast.Type_Ref{qualifier = qualifier, name = type_name, args = args})

	// `x is T` in a return type: a type predicate.
	predicate := peek(p)
	if is_word(predicate, "is") && !predicate.line_break_before {
		report_unsupported(p, .Type_Predicates, advance(p).span)
		parse_type(p)
		return discard(p, m, start)
	}
	return type
}

// is_type_operand reports whether token can start the type after a type operator such as `keyof`.
is_type_operand :: proc(token: Token) -> bool {
	#partial switch token.kind {
	case .Identifier, .Open_Paren, .Open_Bracket, .Open_Brace, .String, .Number, .Typeof:
		return !token.line_break_before
	}
	return false
}

// parse_type_arguments parses `<A, B>`. Each `>` is its own token, so `>>` closes two lists.
parse_type_arguments :: proc(p: ^Parser) -> []ast.Node_ID {
	advance(p) // <
	first := len(p.scratch)
	if at(p, .Greater) {
		error_expected(p, "a type")
	}
	for !at(p, .Greater) && !at(p, .EOF) {
		append(&p.scratch, parse_type(p))
		if !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Greater)
	return finish_list(p, first)
}

// parse_type_params parses `<T, U>`. Constraints and defaults are outside the subset.
parse_type_params :: proc(p: ^Parser) -> []ast.Node_ID {
	advance(p) // <
	first := len(p.scratch)
	if at(p, .Greater) {
		error_expected(p, "a name")
	}
	for !at(p, .Greater) && !at(p, .EOF) {
		start := token_start(p)
		name := parse_type_name(p)
		if at(p, .Extends) {
			m := mark(p)
			report_unsupported(p, .Type_Parameter_Constraints, advance(p).span)
			parse_type(p)
			drop(p, m)
		}
		if at(p, .Equal) {
			m := mark(p)
			report_unsupported(p, .Type_Parameter_Defaults, advance(p).span)
			parse_type(p)
			drop(p, m)
		}
		append(&p.scratch, add_node(p, start, ast.Type_Param{name = name}))
		if !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Greater)
	return finish_list(p, first)
}

// starts_function_type reports whether the `(` at the current token opens the parameters of a
// function type, `(x: T) => U`, rather than a type in parentheses. It is tsc's
// isUnambiguouslyStartOfFunctionType, which reads only what follows the `(`: a `)` or a `...`, or
// a parameter followed by `:`, `,`, `?`, `=` or `) =>`. Whether an arrow follows the matching `)`
// cannot tell: in `(k): ((a: number) => number) => ...` the result type is followed by the arrow
// of its own function.
starts_function_type :: proc(p: ^Parser) -> bool {
	#partial switch peek(p, 1).kind {
	case .Close_Paren, .Dot_Dot_Dot:
		return true
	case .Identifier, .This:
		return starts_parameter_rest(p, p.current + 2)
	case .Open_Brace, .Open_Bracket:
		// A destructured parameter, which the parameter list reports.
		close := matching_close(p, p.current + 1)
		return close >= 0 && starts_parameter_rest(p, close + 1)
	}
	return false
}

// starts_parameter_rest reports whether the token at `at`, after a parameter's name, goes on as a
// parameter list does.
@(private = "file")
starts_parameter_rest :: proc(p: ^Parser, at: int) -> bool {
	#partial switch p.tokens[min(at, len(p.tokens) - 1)].kind {
	case .Colon, .Comma, .Question, .Equal:
		return true
	case .Close_Paren:
		return p.tokens[min(at + 1, len(p.tokens) - 1)].kind == .Arrow
	}
	return false
}

// parse_function_type parses `<U>(params) => type`.
parse_function_type :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	type_params: []ast.Node_ID
	if at(p, .Less) {
		type_params = parse_type_params(p)
	}
	params := parse_params(p)
	expect(p, .Arrow)
	return_type := parse_type(p)
	function := ast.Function_Type {
		type_params = type_params,
		params      = params,
		return_type = return_type,
	}
	return add_node(p, start, function)
}

// parse_params parses the `(a: T, b?: U, ...c: V[])` of a function, an arrow or a function type.
// A rest parameter comes last, with no comma after it.
parse_params :: proc(p: ^Parser) -> []ast.Node_ID {
	first := len(p.scratch)
	if !expect(p, .Open_Paren) {
		return nil
	}
	for !at(p, .Close_Paren) && !at(p, .EOF) {
		param := parse_param(p)
		is_rest := false
		if param != ast.NO_NODE {
			append(&p.scratch, param)
			is_rest = p.nodes[param].variant.(ast.Param).kind == .Rest
		}
		if is_rest || !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Close_Paren)
	return finish_list(p, first)
}

// parse_param reports and leaves out a `this` parameter, a decorator and a default value: they are
// outside the subset.
parse_param :: proc(p: ^Parser) -> ast.Node_ID {
	parse_decorators(p)
	if at(p, .This) {
		m := mark(p)
		report_unsupported(p, .This_Parameters, advance(p).span)
		if accept(p, .Colon) {
			parse_type(p)
		}
		drop(p, m)
		return ast.NO_NODE
	}

	start := token_start(p)
	kind := ast.Param_Kind.Required
	if accept(p, .Dot_Dot_Dot) {
		kind = .Rest
	}
	name := parse_binding_name(p)
	if kind != .Rest && accept(p, .Question) {
		kind = .Optional
	}
	type := ast.NO_NODE
	if accept(p, .Colon) {
		type = parse_type(p)
	}
	if at(p, .Equal) {
		m := mark(p)
		report_unsupported(p, .Default_Parameter_Values, advance(p).span)
		parse_assignment(p)
		drop(p, m)
	}
	return add_node(p, start, ast.Param{name = name, type = type, kind = kind})
}

// parse_object_type parses `{ members }`, a type literal or the body of an interface. Members end
// with `;`, `,` or a line break. A member outside the subset is reported and left out.
parse_object_type :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	if !expect(p, .Open_Brace) {
		// An empty type, not a Bad node: the body of an interface is always an Object_Type.
		return add_node(p, start, ast.Object_Type{})
	}
	first := len(p.scratch)
	for !at(p, .Close_Brace) && !at(p, .EOF) {
		before := p.current
		member := parse_member(p)
		if member != ast.NO_NODE {
			append(&p.scratch, member)
		}
		end_member(p)
		if p.current == before {
			error_unexpected(p)
			advance(p)
		}
	}
	expect(p, .Close_Brace)
	return add_node(p, start, ast.Object_Type{members = finish_list(p, first)})
}

// parse_member parses `readonly name?: type` or a method signature `name<U>(params): type`.
parse_member :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	flags: ast.Member_Flags
	if at_word(p, "readonly") && starts_member_name(peek(p, 1)) {
		advance(p)
		flags += {.Readonly}
	}

	token := peek(p)
	next := peek(p, 1)
	#partial switch token.kind {
	case .Open_Bracket:
		return skip_unsupported_member(p, .Index_Signatures, token.span)
	case .Open_Paren, .Less:
		return skip_unsupported_member(p, .Call_Signatures, token.span)
	case .New:
		return skip_unsupported_member(p, .Construct_Signatures, token.span)
	case .Number:
		return skip_unsupported_member(p, .Number_Property_Keys, token.span)
	}
	if (is_word(token, "get") || is_word(token, "set")) && starts_member_name(next) {
		return skip_unsupported_member(p, .Getters_And_Setters, token.span)
	}
	if !is_name_token(token) && token.kind != .String {
		error_expected(p, "a property name")
		return ast.NO_NODE
	}

	advance(p)
	name := ast.Name {
		text = token.value.(string),
		span = token.span,
	}
	if accept(p, .Question) {
		flags += {.Optional}
	}
	type: ast.Node_ID
	switch {
	case at(p, .Open_Paren) || at(p, .Less):
		type = parse_method_type(p)
	case accept(p, .Colon):
		type = parse_type(p)
	case:
		// Without a type the member would be `any`, which tsc --strict rejects.
		error_expected(p, "`:`")
		type = add_missing(p)
	}
	return add_node(p, start, ast.Property_Signature{flags = flags, name = name, type = type})
}

// parse_method_type parses the `<U>(params): type` of a method signature into a Function_Type.
parse_method_type :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	type_params: []ast.Node_ID
	if at(p, .Less) {
		type_params = parse_type_params(p)
	}
	params := parse_params(p)
	return_type: ast.Node_ID
	if accept(p, .Colon) {
		return_type = parse_type(p)
	} else {
		error_expected(p, "`:`")
		return_type = add_missing(p)
	}
	function := ast.Function_Type {
		type_params = type_params,
		params      = params,
		return_type = return_type,
	}
	return add_node(p, start, function)
}

end_member :: proc(p: ^Parser) {
	if accept(p, .Semicolon) || accept(p, .Comma) {
		return
	}
	token := peek(p)
	if token.kind == .Close_Brace || token.kind == .EOF || token.line_break_before {
		return
	}
	error_expected(p, "`;`")
	skip_member(p)
	if !accept(p, .Semicolon) {
		accept(p, .Comma)
	}
}
