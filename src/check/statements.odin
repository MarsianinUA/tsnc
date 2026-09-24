package check

import "../ast"
import "../bind"

@(private)
check_statements :: proc(c: ^Checker, statements: []ast.Node_ID) {
	for id in statements {
		check_statement(c, id)
	}
}

// check_statement sends anything it does not name to check_expression, which is the exhaustive
// switch over the shapes of ast: a statement slot may hold an expression instead, since the header
// of a `for` is written either way.
//
// A declaration is typed through its symbol rather than here, so that a name used above its
// declaration, a name used below it and a name never used at all all get the work done exactly
// once, and one mistake inside a function body is reported once.
@(private)
check_statement :: proc(c: ^Checker, id: ast.Node_ID) {
	if id == ast.NO_NODE {
		return
	}

	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Var_Decl:
		check_declaration_rules(c, id)
		for declarator in v.declarators {
			check_declarator(c, declarator)
		}
	case ast.Function_Decl:
		check_declaration_rules(c, id)
		check_declaration(c, id)
	case ast.Interface_Decl, ast.Type_Alias_Decl:
		check_declaration_rules(c, id)
		// A type declaration is read here as well as where a name uses it, so that a mistake inside
		// one is found even where nothing names it. Both paths answer from the same cache, so the
		// members are read once either way.
		check_type_declaration(c, id)
	case ast.Import_Named:
		check_import(c, id, v)
	case ast.Export_Named:
		check_export(c, id, v)
	case ast.Import_Namespace:
	// `import * as m` names nothing of the other module by itself, so there is nothing to resolve
	// until a name follows the dot.

	case ast.Block:
		check_statements(c, v.statements)
	case ast.Expr_Stmt:
		check_expression(c, v.expr)
	case ast.If:
		// TypeScript asks nothing of a condition: every value is either truthy or falsy.
		check_expression(c, v.condition)
		check_statement(c, v.then_branch)
		check_statement(c, v.else_branch)
	case ast.While:
		check_expression(c, v.condition)
		check_statement(c, v.body)
	case ast.Do_While:
		check_statement(c, v.body)
		check_expression(c, v.condition)
	case ast.For:
		check_statement(c, v.init)
		check_expression(c, v.condition)
		check_expression(c, v.update)
		check_statement(c, v.body)
	case ast.For_Of:
		iterable := check_expression(c, v.iterable)
		for_of_variable(c, v.declaration, for_of_element(c, v.iterable, iterable))
		check_statement(c, v.body)
	case ast.Switch:
		subject := check_expression(c, v.value)
		for clause in v.cases {
			node := c.at.tree.nodes[clause].variant.(ast.Case)
			value := check_expression(c, node.value)
			// A case the subject can never equal is a case that never runs, so it is a mistake and
			// not a test, exactly as `===` between two such types is.
			if node.value != ast.NO_NODE && !comparable(c, subject, value) {
				report_types(c, .No_Overlap, span_of(c, node.value), subject, value)
			}
			check_statements(c, node.statements)
		}
	case ast.Return:
		check_return(c, id, v)
	case ast.Break, ast.Continue, ast.Empty:
	// bind has already reported a jump that leads nowhere.

	case:
		check_expression(c, id)
	}
}

@(private)
check_declarator :: proc(c: ^Checker, id: ast.Node_ID) {
	symbol := c.at.bound.node_symbols[id]
	if symbol == bind.NO_SYMBOL {
		// parse could not read the name, so there is nothing to record an answer under. The parts
		// are still typed, so a mistake inside them is found.
		node := c.at.tree.nodes[id].variant.(ast.Declarator)
		resolve_type(c, node.type)
		check_expression(c, node.init)
		return
	}
	type_of_symbol(c, {file = c.at.file, symbol = symbol})
}

// check_declaration types a declaration that names itself, which is every one but a declarator.
@(private)
check_declaration :: proc(c: ^Checker, id: ast.Node_ID) {
	symbol := c.at.bound.node_symbols[id]
	if symbol == bind.NO_SYMBOL {
		return // parse could not read the name and has reported it
	}
	type_of_symbol(c, {file = c.at.file, symbol = symbol})
}

// check_type_declaration skips a generic declaration, which is read only where it is used, with its
// arguments in force: on its own there is nothing to put in place of its type parameters.
@(private)
check_type_declaration :: proc(c: ^Checker, id: ast.Node_ID) {
	symbol := c.at.bound.node_symbols[id]
	if symbol == bind.NO_SYMBOL {
		return // parse could not read the name and has reported it
	}

	type_params: []ast.Node_ID
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Interface_Decl:
		type_params = v.type_params
	case ast.Type_Alias_Decl:
		type_params = v.type_params
	}
	if len(type_params) > 0 {
		return
	}

	named_type(c, {file = c.at.file, symbol = symbol}, nil, c.at.bound.symbols[symbol].name)
}

// for_of_element knows an array and a string by itself, exactly as check_index knows that `a[i]` is
// an element and `s[i]` a string: requirements 2.2 loops over the two, and the lib file declares no
// iterator.
//
// A union is refused rather than taken apart: requirements 3.4 keeps a union as a tagged value, so
// `number[] | string[]` would need a tag test on every turn of the loop. Narrowing the value first is
// the shorter way to say the same thing, and the hint asks for it.
@(private)
for_of_element :: proc(c: ^Checker, iterable: ast.Node_ID, type: Type_ID) -> Type_ID {
	if type == ERROR {
		return ERROR // a value the rules already gave up on says nothing more here
	}
	if type == ANY {
		report_any(c, span_of(c, iterable), "be looped over with `for...of`")
		return ERROR
	}
	if array, is_array := c.table.types[type].(Array); is_array {
		return array.element
	}
	if based_on(c, type, STRING) {
		return STRING
	}
	report(c, .Not_Iterable, span_of(c, iterable), text_of(c, type))
	return ERROR
}

// for_of_variable must not go through the usual path, which would see a `let` with neither an
// annotation nor an initializer and ask for one: the `of` is where the type comes from.
@(private)
for_of_variable :: proc(c: ^Checker, declaration: ast.Node_ID, element: Type_ID) {
	if declaration == ast.NO_NODE {
		return
	}
	node, is_var := c.at.tree.nodes[declaration].variant.(ast.Var_Decl)
	if !is_var {
		return
	}
	for declarator in node.declarators {
		if symbol := c.at.bound.node_symbols[declarator]; symbol != bind.NO_SYMBOL {
			c.symbol_types[{file = c.at.file, symbol = symbol}] = element
		}
		set_type(c, declarator, element)
	}
}

// check_return leaves VOID as the marker of a bare `return` while a result is being inferred:
// inferred_result reads it as `void` where every `return` is bare, which is what tsc infers for a
// body that returns no value at all, and as `undefined` where one of them does return a value.
//
// At the top level of a module there is no function and no declared result, so a stray `return`
// value is measured against the error type and passes. Whether it may stand there at all is bind's
// question, next to the two jumps it already answers: it reports Return_Outside_Function.
@(private)
check_return :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Return) {
	if node.value == ast.NO_NODE {
		if c.at.returns != nil {
			append(c.at.returns, VOID)
			return
		}
		if !fits(c, UNDEFINED, c.at.result) {
			report_types(c, .Type_Mismatch, span_of(c, id), UNDEFINED, c.at.result)
		}
		return
	}

	value := check_expression(c, node.value, c.at.result)
	if c.at.returns != nil {
		append(c.at.returns, value)
		return
	}
	if !fits(c, value, c.at.result) {
		report_assign_failure(c, span_of(c, node.value), value, c.at.result)
	}
}
