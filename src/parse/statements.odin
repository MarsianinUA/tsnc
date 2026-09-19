#+private
package parse

import "../ast"

// parse_module_items parses the statements, imports and exports of a module up to closer: the end
// of the file, or the `}` of a namespace body.
parse_module_items :: proc(p: ^Parser, closer: Token_Kind) -> []ast.Node_ID {
	first := len(p.scratch)
	for !at(p, closer) && !at(p, .EOF) {
		before := p.current
		add_item(p, parse_module_item(p), before)
	}
	return finish_list(p, first)
}

// parse_block_items parses the statements of a block up to its `}`.
parse_block_items :: proc(p: ^Parser) -> []ast.Node_ID {
	first := len(p.scratch)
	for !at(p, .Close_Brace) && !at(p, .EOF) {
		before := p.current
		add_item(p, parse_block_item(p), before)
	}
	return finish_list(p, first)
}

// add_item appends an item that a list loop parsed to the list in scratch. An item that read
// nothing started at a token that starts no statement: it is reported and skipped, so that the
// loop moves on.
add_item :: proc(p: ^Parser, item: ast.Node_ID, before: int) {
	if item != ast.NO_NODE {
		append(&p.scratch, item)
	}
	if p.current == before {
		error_unexpected(p)
		advance(p)
	}
}

parse_module_item :: proc(p: ^Parser) -> ast.Node_ID {
	#partial switch peek(p).kind {
	case .Import:
		if !starts_import_expression(p) {
			return parse_import(p)
		}
	case .Export:
		return parse_export(p)
	case .At:
		parse_decorators(p)
		return parse_module_item(p)
	}
	return parse_block_item(p)
}

// parse_block_item parses a statement or a declaration: an item of a block or a case.
parse_block_item :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return ast.NO_NODE
	}
	defer leave(p)

	token := peek(p)
	#partial switch token.kind {
	case .Import, .Export:
		if token.kind == .Import && starts_import_expression(p) {
			break
		}
		// Imports and exports stand only at the top level of a module.
		error_unexpected(p)
		m := mark(p)
		parse_module_item(p)
		return discard(p, m, token.span.start)
	case .At:
		parse_decorators(p)
		return parse_block_item(p)
	case .Let, .Const, .Var, .Function, .Class, .Enum, .Interface:
		return parse_declaration(p, token.span.start, {})
	case .Identifier:
		if starts_declaration_word(p) {
			return parse_declaration(p, token.span.start, {})
		}
	}
	return parse_statement(p)
}

// starts_import_expression reports whether the current `import` starts `import(...)` or
// `import.meta` rather than an import declaration.
starts_import_expression :: proc(p: ^Parser) -> bool {
	next := peek(p, 1).kind
	return next == .Open_Paren || next == .Dot
}

// starts_declaration_word reports whether the current name is a contextual keyword that starts a
// declaration here: the token after it must be on the same line.
starts_declaration_word :: proc(p: ^Parser) -> bool {
	if !next_on_same_line(p) {
		return false
	}
	next := peek(p, 1)
	switch peek(p).value.(string) {
	case "type":
		return next.kind == .Identifier
	case "declare":
		return is_name_token(next)
	case "namespace", "module":
		return next.kind == .Identifier || next.kind == .String
	case "abstract":
		return next.kind == .Class
	case "async":
		return next.kind == .Function
	}
	return false
}

// Declarations.

// parse_declaration parses a declaration that starts at the current token, after the modifiers
// already read from start on (`export`, `declare`).
parse_declaration :: proc(p: ^Parser, start: i32, modifiers: ast.Modifiers) -> ast.Node_ID {
	token := peek(p)
	#partial switch token.kind {
	case .Let, .Const:
		if token.kind == .Const && peek(p, 1).kind == .Enum {
			return parse_enum(p, start)
		}
		return parse_var_decl(p, start, modifiers)
	case .Var:
		m := mark(p)
		report_subset(p, .Var_Declaration, token.span)
		parse_var_decl(p, start, modifiers)
		return discard(p, m, start)
	case .Function:
		return parse_function_decl(p, start, modifiers)
	case .Interface:
		return parse_interface(p, start, modifiers)
	case .Class:
		return parse_class(p, start)
	case .Enum:
		return parse_enum(p, start)
	case .Identifier:
		next := peek(p, 1)
		switch token.value.(string) {
		case "type":
			if next.kind == .Identifier {
				return parse_type_alias(p, start, modifiers)
			}
		case "declare":
			if .Declare not_in modifiers && is_name_token(next) {
				advance(p)
				return parse_declaration(p, start, modifiers + {.Declare})
			}
		case "namespace", "module", "global":
			return parse_namespace(p, start)
		case "abstract":
			if next.kind == .Class {
				return parse_class(p, start)
			}
		case "async":
			if next.kind == .Function {
				m := mark(p)
				report_subset(p, .Async, advance(p).span)
				parse_function_decl(p, start, modifiers)
				return discard(p, m, start)
			}
		}
	}
	error_expected(p, "a declaration")
	skip_statement(p)
	return add_node(p, start, ast.Bad{})
}

// parse_var_decl parses `let a = 1, b: T;` from its keyword.
parse_var_decl :: proc(p: ^Parser, start: i32, modifiers: ast.Modifiers) -> ast.Node_ID {
	keyword := advance(p)
	kind: ast.Var_Kind = .Const if keyword.kind == .Const else .Let
	declarators := parse_declarator_list(p, parse_declarator(p), kind, modifiers)
	end_statement(p)
	return add_node(
		p,
		start,
		ast.Var_Decl{modifiers = modifiers, kind = kind, declarators = declarators},
	)
}

// parse_declarator_list parses the declarators of a `let` or `const` after the first one, which
// the caller has already parsed: a `for` header reads it before it knows whether a list or `of`
// follows. The list holds them all, the first included.
parse_declarator_list :: proc(
	p: ^Parser,
	first_declarator: ast.Node_ID,
	kind: ast.Var_Kind,
	modifiers: ast.Modifiers,
) -> []ast.Node_ID {
	first := len(p.scratch)
	declarator := first_declarator
	for {
		check_initialized(p, kind, modifiers, declarator)
		append(&p.scratch, declarator)
		if !accept(p, .Comma) {
			break
		}
		declarator = parse_declarator(p)
	}
	return finish_list(p, first)
}

// parse_declarator parses `name: type = init`.
parse_declarator :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	name := parse_binding_name(p)
	type := ast.NO_NODE
	if accept(p, .Colon) {
		type = parse_type(p)
	}
	init := ast.NO_NODE
	if accept(p, .Equal) {
		init = parse_assignment(p)
	}
	return add_node(p, start, ast.Declarator{name = name, type = type, init = init})
}

// check_initialized reports a `const` declarator without a value, which only `declare` allows.
// The current token is the one after the declarator.
check_initialized :: proc(
	p: ^Parser,
	kind: ast.Var_Kind,
	modifiers: ast.Modifiers,
	declarator: ast.Node_ID,
) {
	has_init := p.nodes[declarator].variant.(ast.Declarator).init != ast.NO_NODE
	if kind == .Const && .Declare not_in modifiers && !has_init {
		error_expected(p, "`=`")
	}
}

// parse_binding_name parses the name a declaration or a parameter introduces. A destructuring
// pattern in its place is outside the subset: it is reported and skipped, and the name stays
// empty.
parse_binding_name :: proc(p: ^Parser) -> ast.Name {
	token := peek(p)
	#partial switch token.kind {
	case .Identifier:
		advance(p)
		name := name_of(token)
		check_binding_name(p, name)
		return name
	case .Open_Brace, .Open_Bracket:
		report_subset(p, .Destructuring, token.span)
		skip_balanced(p)
		return missing_name(p)
	}
	error_expected(p, "a name")
	return missing_name(p)
}

// check_binding_name reports a variable or a parameter named `arguments` or `eval`: strict mode
// forbids both names.
check_binding_name :: proc(p: ^Parser, name: ast.Name) {
	switch name.text {
	case "arguments":
		report_subset(p, .Arguments_Object, name.span)
	case "eval":
		report_subset(p, .Eval, name.span)
	}
}

// parse_type_name parses the name of an interface, a type alias or a type parameter.
parse_type_name :: proc(p: ^Parser) -> ast.Name {
	if at(p, .Identifier) {
		return name_of(advance(p))
	}
	error_expected(p, "a name")
	return missing_name(p)
}

// parse_function_decl parses `function name<T>(params): type { body }`. Only `declare` allows a
// function without a body; one without `declare` is an overload signature, outside the subset. A
// function with a syntax error is not reported as one: its body is more likely missing because of
// that error, as in `function f() return 1`.
parse_function_decl :: proc(p: ^Parser, start: i32, modifiers: ast.Modifiers) -> ast.Node_ID {
	m := mark(p)
	keyword := advance(p)
	is_generator := at(p, .Star)
	if is_generator {
		report_unsupported(p, .Generators, advance(p).span)
	}
	name := parse_binding_name(p)
	function := parse_function_rest(p, start, modifiers, name)
	if is_generator {
		return discard(p, m, start)
	}
	has_body := p.nodes[function].variant.(ast.Function_Decl).body != ast.NO_NODE
	if has_body || .Declare in modifiers {
		return function
	}
	if p.errors_seen == m.errors_seen {
		report_unsupported(p, .Function_Overloads, keyword.span)
	}
	return discard(p, m, start)
}

// parse_function_rest parses a function from its type parameters on, after its name.
parse_function_rest :: proc(
	p: ^Parser,
	start: i32,
	modifiers: ast.Modifiers,
	name: ast.Name,
) -> ast.Node_ID {
	type_params: []ast.Node_ID
	if at(p, .Less) {
		type_params = parse_type_params(p)
	}
	params := parse_params(p)
	return_type := ast.NO_NODE
	if accept(p, .Colon) {
		return_type = parse_type(p)
	}
	body := ast.NO_NODE
	if at(p, .Open_Brace) {
		body = parse_block(p)
	} else {
		end_statement(p)
	}
	function := ast.Function_Decl {
		modifiers   = modifiers,
		name        = name,
		type_params = type_params,
		params      = params,
		return_type = return_type,
		body        = body,
	}
	return add_node(p, start, function)
}

// parse_interface parses `interface Name<T> { members }`.
parse_interface :: proc(p: ^Parser, start: i32, modifiers: ast.Modifiers) -> ast.Node_ID {
	advance(p) // interface
	name := parse_type_name(p)
	type_params: []ast.Node_ID
	if at(p, .Less) {
		type_params = parse_type_params(p)
	}
	if at(p, .Extends) {
		m := mark(p)
		report_unsupported(p, .Interface_Extends_Clauses, advance(p).span)
		for {
			parse_type(p)
			if !accept(p, .Comma) {
				break
			}
		}
		drop(p, m)
	}
	body := parse_object_type(p)
	interface := ast.Interface_Decl {
		modifiers   = modifiers,
		name        = name,
		type_params = type_params,
		body        = body,
	}
	return add_node(p, start, interface)
}

// parse_type_alias parses `type Name<T> = type;`.
parse_type_alias :: proc(p: ^Parser, start: i32, modifiers: ast.Modifiers) -> ast.Node_ID {
	advance(p) // type
	name := parse_type_name(p)
	type_params: []ast.Node_ID
	if at(p, .Less) {
		type_params = parse_type_params(p)
	}
	expect(p, .Equal)
	type := parse_type(p)
	end_statement(p)
	alias := ast.Type_Alias_Decl {
		modifiers   = modifiers,
		name        = name,
		type_params = type_params,
		type        = type,
	}
	return add_node(p, start, alias)
}

// Imports and exports.

// parse_import parses `import { a, b as c } from "./m"`, `import * as m from "./m"` and
// `import "./m"`, each optionally `import type`. A default import is outside the subset.
parse_import :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	advance(p) // import

	if at(p, .String) {
		path, _ := parse_module_path(p)
		end_statement(p)
		return add_node(p, start, ast.Import_Named{path = path})
	}

	type_only := false
	next := peek(p, 1).kind
	if at_word(p, "type") && (next == .Open_Brace || next == .Star) {
		advance(p)
		type_only = true
	}

	token := peek(p)
	#partial switch token.kind {
	case .Open_Brace:
		specifiers := parse_specifiers(p)
		// The local name of an import is a binding: `import { x as eval }` is an `eval`.
		for id in specifiers {
			check_binding_name(p, p.nodes[id].variant.(ast.Specifier).alias)
		}
		expect_word(p, "from")
		path, has_path := parse_module_path(p)
		end_statement(p)
		if !has_path {
			return discard(p, m, start)
		}
		import_named := ast.Import_Named {
			type_only  = type_only,
			specifiers = specifiers,
			path       = path,
		}
		return add_node(p, start, import_named)
	case .Star:
		advance(p)
		expect_word(p, "as")
		name := parse_binding_name(p)
		expect_word(p, "from")
		path, has_path := parse_module_path(p)
		end_statement(p)
		if !has_path {
			return discard(p, m, start)
		}
		import_namespace := ast.Import_Namespace {
			type_only = type_only,
			name      = name,
			path      = path,
		}
		return add_node(p, start, import_namespace)
	case .Identifier:
		if peek(p, 1).kind == .Equal {
			report_unsupported(p, .Import_Equals_Aliases, token.span)
		} else {
			report_subset(p, .Default_Export, token.span)
		}
		skip_statement(p)
		return discard(p, m, start)
	}
	error_expected(p, "`{`")
	skip_statement(p)
	return discard(p, m, start)
}

// parse_export parses `export { a, b as c }` with or without `from "./m"`, `export type { }` and
// `export` before a declaration. `export default`, `export *`, `export =` and `export import` are
// outside the subset.
parse_export :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	advance(p) // export

	token := peek(p)
	#partial switch token.kind {
	case .Open_Brace:
		return parse_export_list(p, m, start, type_only = false)
	case .Default:
		report_subset(p, .Default_Export, advance(p).span)
		parse_default_export_value(p)
		return discard(p, m, start)
	case .Star:
		report_unsupported(p, .Export_Star_Declarations, token.span)
		skip_statement(p)
		return discard(p, m, start)
	case .Equal:
		report_unsupported(p, .Export_Assignments, advance(p).span)
		parse_expression(p)
		end_statement(p)
		return discard(p, m, start)
	case .Import:
		report_unsupported(p, .Export_Import_Aliases, token.span)
		skip_statement(p)
		return discard(p, m, start)
	case .Identifier:
		if is_word(token, "type") && peek(p, 1).kind == .Open_Brace {
			advance(p)
			return parse_export_list(p, m, start, type_only = true)
		}
	}
	return parse_declaration(p, start, {.Export})
}

// parse_export_list parses the `{ a, b as c }` of an export and the `from "./m"` after it.
parse_export_list :: proc(p: ^Parser, m: Mark, start: i32, type_only: bool) -> ast.Node_ID {
	specifiers := parse_specifiers(p)
	path := ast.NO_NODE
	if accept_word(p, "from") {
		has_path: bool
		path, has_path = parse_module_path(p)
		if !has_path {
			end_statement(p)
			return discard(p, m, start)
		}
	}
	end_statement(p)
	export := ast.Export_Named {
		type_only  = type_only,
		specifiers = specifiers,
		path       = path,
	}
	return add_node(p, start, export)
}

// parse_default_export_value parses what follows `export default`, so that the errors inside it
// are found too.
parse_default_export_value :: proc(p: ^Parser) {
	start := token_start(p)
	if at_word(p, "async") && peek(p, 1).kind == .Function {
		report_subset(p, .Async, advance(p).span)
	}
	if !accept(p, .Function) {
		if starts_declaration(p) {
			parse_block_item(p)
		} else {
			parse_assignment(p)
			end_statement(p)
		}
		return
	}
	// The function may have no name here.
	accept(p, .Star)
	name: ast.Name
	if at(p, .Identifier) {
		name = name_of(advance(p))
	}
	parse_function_rest(p, start, {}, name)
}

// starts_declaration reports whether a declaration starts at the current token.
starts_declaration :: proc(p: ^Parser) -> bool {
	#partial switch peek(p).kind {
	case .Let, .Const, .Var, .Function, .Class, .Enum, .Interface:
		return true
	case .Identifier:
		return starts_declaration_word(p)
	}
	return false
}

// parse_specifiers parses `{ a, b as c, type d }` of an import or an export. A specifier outside
// the subset is reported and left out.
parse_specifiers :: proc(p: ^Parser) -> []ast.Node_ID {
	first := len(p.scratch)
	expect(p, .Open_Brace)
	for !at(p, .Close_Brace) && !at(p, .EOF) {
		specifier := parse_specifier(p)
		if specifier != ast.NO_NODE {
			append(&p.scratch, specifier)
		}
		if !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Close_Brace)
	return finish_list(p, first)
}

parse_specifier :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	type_only := false
	next := peek(p, 1)
	if at_word(p, "type") && is_name_token(next) && !is_word(next, "as") {
		advance(p)
		type_only = true
	}

	token := peek(p)
	if token.kind == .String {
		report_unsupported(p, .String_Specifiers, token.span)
		advance(p)
		if accept_word(p, "as") {
			advance(p)
		}
		return ast.NO_NODE
	}
	if !is_name_token(token) {
		error_expected(p, "a name")
		return ast.NO_NODE
	}
	name := name_of(advance(p))
	alias := name
	if accept_word(p, "as") {
		alias_token := peek(p)
		if alias_token.kind == .String {
			report_unsupported(p, .String_Specifiers, alias_token.span)
			advance(p)
			return ast.NO_NODE
		}
		if is_name_token(alias_token) {
			alias = name_of(advance(p))
		} else {
			error_expected(p, "a name")
		}
	}

	// `default` is the default export.
	if name.text == "default" || alias.text == "default" {
		default_name := name if name.text == "default" else alias
		report_subset(p, .Default_Export, default_name.span)
		return ast.NO_NODE
	}
	return add_node(p, start, ast.Specifier{type_only = type_only, name = name, alias = alias})
}

// parse_module_path parses the `"./m"` of an import or a re-export; ok is false when it is
// missing. An import attributes clause after it is outside the subset.
parse_module_path :: proc(p: ^Parser) -> (path: ast.Node_ID, ok: bool) {
	if !at(p, .String) {
		error_expected(p, "a module path string")
		return ast.NO_NODE, false
	}
	token := advance(p)
	path = add_node(p, token.span.start, ast.String_Literal{value = token.value.(string)})
	if at(p, .With) {
		report_unsupported(p, .Import_Attributes, advance(p).span)
		if at(p, .Open_Brace) {
			skip_balanced(p)
		}
	}
	return path, true
}

// Constructs outside the subset.

// parse_decorators reports every decorator `@expr` in a row and reads it. They make no node: the
// declaration after them then parses on its own. A loop, not recursion, so that a long run of them
// is not deep nesting.
parse_decorators :: proc(p: ^Parser) {
	for at(p, .At) {
		m := mark(p)
		report_subset(p, .Decorator, advance(p).span)
		parse_postfix(p)
		drop(p, m)
	}
}

// parse_class reports a class and skips it to the end of its body, which is not parsed.
parse_class :: proc(p: ^Parser, start: i32) -> ast.Node_ID {
	m := mark(p)
	report_subset(p, .Class, peek(p).span)
	skip_to_body_end(p)
	return discard(p, m, start)
}

// parse_enum reports an enum and skips it to the end of its body.
parse_enum :: proc(p: ^Parser, start: i32) -> ast.Node_ID {
	m := mark(p)
	report_subset(p, .Enum, peek(p).span)
	skip_to_body_end(p)
	return discard(p, m, start)
}

// skip_to_body_end skips a declaration up to and including its `{ body }`. A `{` inside type
// arguments is an object type, not the body: `class A extends B<{ x: number }> {}`. The skip stops
// early at a keyword on a new line that starts a statement, so that a missing body or an unclosed
// `<` does not swallow the statements after the declaration.
skip_to_body_end :: proc(p: ^Parser) {
	first := p.current
	type_argument_depth := 0
	for {
		token := peek(p)
		#partial switch token.kind {
		case .Open_Brace:
			skip_balanced(p)
			if type_argument_depth == 0 {
				return
			}
			continue
		case .EOF, .Semicolon, .Close_Brace:
			return
		case .Open_Paren, .Open_Bracket:
			skip_balanced(p)
			continue
		case .Less:
			type_argument_depth += 1
		case .Greater:
			type_argument_depth = max(type_argument_depth - 1, 0)
		}
		if token.line_break_before && starts_statement(token.kind) && p.current > first {
			return
		}
		advance(p)
	}
}

// parse_namespace reports `namespace N { }`, `module N { }` or `declare global { }` and parses its
// body as module items, so that the errors inside it are found too.
parse_namespace :: proc(p: ^Parser, start: i32) -> ast.Node_ID {
	if !enter(p) {
		return ast.NO_NODE
	}
	defer leave(p)

	m := mark(p)
	report_subset(p, .Namespace, advance(p).span)
	// The name: `A.B.C`, or a module string.
	for at(p, .Identifier) || at(p, .String) || at(p, .Dot) {
		advance(p)
	}
	if accept(p, .Open_Brace) {
		parse_module_items(p, .Close_Brace)
		expect(p, .Close_Brace)
	} else {
		end_statement(p)
	}
	return discard(p, m, start)
}

// Statements.

// parse_statement parses a statement. A declaration is not a statement: as the body of an `if` or
// a loop it needs a block, so there it is reported, then parsed anyway. The result is NO_NODE when
// no statement starts at the current token; nothing is read then.
parse_statement :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return ast.NO_NODE
	}
	defer leave(p)

	token := peek(p)
	start := token.span.start
	#partial switch token.kind {
	case .Open_Brace:
		return parse_block(p)
	case .Semicolon:
		advance(p)
		return add_node(p, start, ast.Empty{})
	case .If:
		return parse_if(p)
	case .Switch:
		return parse_switch(p)
	case .For:
		return parse_for(p)
	case .While:
		return parse_while(p)
	case .Do:
		return parse_do_while(p)
	case .Break, .Continue:
		return parse_jump(p)
	case .Return:
		return parse_return(p)
	case .With:
		return parse_with(p)
	case .Try:
		return parse_try(p)
	case .Throw:
		m := mark(p)
		report_subset(p, .Exception, advance(p).span, "throw")
		parse_expression(p)
		end_statement(p)
		return discard(p, m, start)
	case .Debugger:
		report_unsupported(p, .Debugger_Statements, advance(p).span)
		end_statement(p)
		return add_node(p, start, ast.Bad{})
	case .Let, .Const, .Function, .Class, .Enum, .Interface:
		error_unexpected(p)
		return parse_block_item(p)
	case .Import:
		if !starts_import_expression(p) {
			return parse_block_item(p)
		}
	case .Var, .Export, .At:
		return parse_block_item(p)
	case .Identifier:
		if starts_declaration_word(p) {
			error_unexpected(p)
			return parse_block_item(p)
		}
		if peek(p, 1).kind == .Colon {
			report_unsupported(p, .Labels, token.span)
			advance(p)
			advance(p)
			return parse_body(p)
		}
	}
	return parse_expression_statement(p)
}

// parse_body parses the body of an `if` or a loop: a missing one is a zero-width Bad node.
parse_body :: proc(p: ^Parser) -> ast.Node_ID {
	body := parse_statement(p)
	if body == ast.NO_NODE {
		error_expected(p, "a statement")
		body = add_missing(p)
	}
	return body
}

parse_expression_statement :: proc(p: ^Parser) -> ast.Node_ID {
	if !can_start_expression(peek(p).kind) {
		return ast.NO_NODE
	}
	start := token_start(p)
	expr := parse_expression(p)
	end_statement(p)
	return add_node(p, start, ast.Expr_Stmt{expr = expr})
}

parse_block :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	start := token_start(p)
	if !expect(p, .Open_Brace) {
		return add_missing(p)
	}
	statements := parse_block_items(p)
	expect(p, .Close_Brace)
	return add_node(p, start, ast.Block{statements = statements})
}

parse_if :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // if
	condition := parse_condition(p)
	then_branch := parse_body(p)
	else_branch := ast.NO_NODE
	if accept(p, .Else) {
		else_branch = parse_body(p)
	}
	branches := ast.If {
		condition   = condition,
		then_branch = then_branch,
		else_branch = else_branch,
	}
	return add_node(p, start, branches)
}

// parse_condition parses the `(expression)` of an `if`, a `while` or a `switch`.
parse_condition :: proc(p: ^Parser) -> ast.Node_ID {
	expect(p, .Open_Paren)
	condition := parse_expression(p)
	expect(p, .Close_Paren)
	return condition
}

parse_switch :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // switch
	value := parse_condition(p)
	first := len(p.scratch)
	if expect(p, .Open_Brace) {
		for !at(p, .Close_Brace) && !at(p, .EOF) {
			if !at(p, .Case) && !at(p, .Default) {
				error_unexpected(p)
				advance(p)
				continue
			}
			append(&p.scratch, parse_case(p))
		}
		expect(p, .Close_Brace)
	}
	return add_node(p, start, ast.Switch{value = value, cases = finish_list(p, first)})
}

// parse_case parses `case value:` or `default:` and the statements after it.
parse_case :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	value := ast.NO_NODE
	if advance(p).kind == .Case {
		value = parse_expression(p)
	}
	expect(p, .Colon)
	first := len(p.scratch)
	for !at(p, .Case) && !at(p, .Default) && !at(p, .Close_Brace) && !at(p, .EOF) {
		before := p.current
		add_item(p, parse_block_item(p), before)
	}
	return add_node(p, start, ast.Case{value = value, statements = finish_list(p, first)})
}

// parse_for parses `for (init; condition; update) body` and `for (const x of xs) body`. The
// header's semicolons are never inserted. `for...in`, `for await` and `for...of` over an existing
// variable are outside the subset.
parse_for :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	keyword := advance(p) // for
	// The loop has been reported and becomes one Bad node.
	is_bad := false
	if at(p, .Await) {
		report_subset(p, .Async, advance(p).span)
		is_bad = true
	}
	expect(p, .Open_Paren)

	init := ast.NO_NODE
	token := peek(p)
	#partial switch token.kind {
	case .Semicolon:
	case .Let, .Const, .Var:
		declaration_mark := mark(p)
		advance(p)
		is_var := token.kind == .Var
		if is_var {
			report_subset(p, .Var_Declaration, token.span)
		}
		kind: ast.Var_Kind = .Const if token.kind == .Const else .Let
		declarator := parse_declarator(p)
		is_for_in := at(p, .In)
		if is_for_in || at_word(p, "of") {
			// A `var` makes the whole loop Bad: `declaration` is no slot for a Bad node.
			is_bad = is_bad || is_var
			if is_for_in {
				report_subset(p, .For_In, keyword.span)
				is_bad = true
			}
			// `for (const x = 1 of xs)`: read as a `for` header, the `;` is missing.
			if p.nodes[declarator].variant.(ast.Declarator).init != ast.NO_NODE {
				error_expected(p, "`;`")
				is_bad = true
			}
			declaration := ast.Var_Decl {
				kind        = kind,
				declarators = one_element(p, declarator),
			}
			loop := parse_for_of_rest(p, start, add_node(p, token.span.start, declaration))
			if is_bad {
				return discard(p, m, start)
			}
			return loop
		}

		declaration := ast.Var_Decl {
			kind        = kind,
			declarators = parse_declarator_list(p, declarator, kind, {}),
		}
		init = add_node(p, token.span.start, declaration)
		if is_var {
			init = discard(p, declaration_mark, token.span.start)
		}
	case:
		next := peek(p, 1)
		if token.kind == .Identifier && (is_word(next, "of") || next.kind == .In) {
			if next.kind == .In {
				report_subset(p, .For_In, keyword.span)
			} else {
				report_unsupported(p, .For_Of_Without_Declaration, keyword.span)
			}
			advance(p)
			parse_for_of_rest(p, start, ast.NO_NODE)
			return discard(p, m, start)
		}
		init = parse_expression(p)
	}

	loop := parse_for_rest(p, start, init)
	if is_bad {
		return discard(p, m, start)
	}
	return loop
}

// parse_for_rest parses the rest of `for (init; condition; update) body` from the `;` after init.
parse_for_rest :: proc(p: ^Parser, start: i32, init: ast.Node_ID) -> ast.Node_ID {
	expect(p, .Semicolon)
	condition := ast.NO_NODE
	if !at(p, .Semicolon) {
		condition = parse_expression(p)
	}
	expect(p, .Semicolon)
	update := ast.NO_NODE
	if !at(p, .Close_Paren) {
		update = parse_expression(p)
	}
	expect(p, .Close_Paren)
	body := parse_body(p)
	loop := ast.For {
		init      = init,
		condition = condition,
		update    = update,
		body      = body,
	}
	return add_node(p, start, loop)
}

// parse_for_of_rest parses the rest of `for (declaration of iterable) body` from `of`, or from
// `in` of a `for...in` that the caller has reported.
parse_for_of_rest :: proc(p: ^Parser, start: i32, declaration: ast.Node_ID) -> ast.Node_ID {
	advance(p) // of or in
	iterable := parse_assignment(p)
	expect(p, .Close_Paren)
	body := parse_body(p)
	loop := ast.For_Of {
		declaration = declaration,
		iterable    = iterable,
		body        = body,
	}
	return add_node(p, start, loop)
}

parse_while :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // while
	condition := parse_condition(p)
	body := parse_body(p)
	return add_node(p, start, ast.While{condition = condition, body = body})
}

// parse_do_while parses `do body while (condition)`. The `;` after it is optional even on the
// same line, as ECMAScript inserts one there.
parse_do_while :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // do
	body := parse_body(p)
	if !accept(p, .While) {
		error_expected(p, "`while`")
	}
	condition := parse_condition(p)
	accept(p, .Semicolon)
	return add_node(p, start, ast.Do_While{body = body, condition = condition})
}

// parse_jump parses `break` or `continue`. A label after it is outside the subset.
parse_jump :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	keyword := advance(p)
	label := peek(p)
	if label.kind == .Identifier && !label.line_break_before {
		report_unsupported(p, .Labels, advance(p).span)
	}
	end_statement(p)
	if keyword.kind == .Break {
		return add_node(p, start, ast.Break{})
	}
	return add_node(p, start, ast.Continue{})
}

// parse_return parses `return value`. A line break after `return` ends the statement.
parse_return :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // return
	value := ast.NO_NODE
	token := peek(p)
	#partial switch token.kind {
	case .Semicolon, .Close_Brace, .EOF:
	case:
		if !token.line_break_before {
			value = parse_expression(p)
		}
	}
	end_statement(p)
	return add_node(p, start, ast.Return{value = value})
}

parse_with :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	report_subset(p, .With_Statement, advance(p).span)
	parse_condition(p)
	parse_body(p)
	return discard(p, m, start)
}

// parse_try reports `try` and parses its blocks, so that the errors inside them are found too.
parse_try :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	report_subset(p, .Exception, advance(p).span, "try")
	parse_block(p)
	if accept(p, .Catch) {
		if at(p, .Open_Paren) {
			skip_balanced(p)
		}
		parse_block(p)
	}
	if accept(p, .Finally) {
		parse_block(p)
	}
	return discard(p, m, start)
}
