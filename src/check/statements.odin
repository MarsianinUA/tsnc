package check

import "../ast"
import "../bind"

// check_statements types a list of statements in source order.
@(private)
check_statements :: proc(c: ^Checker, statements: []ast.Node_ID) {
	for id in statements {
		check_statement(c, id)
	}
}

// check_statement types one statement. A statement slot may hold an expression instead — the header
// of a `for` is written either way — so anything this does not name goes to check_expression, which
// is the exhaustive switch over the shapes of ast.
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
		for declarator in v.declarators {
			check_declarator(c, declarator)
		}
	case ast.Function_Decl:
		check_declaration(c, id)
	case ast.Interface_Decl, ast.Type_Alias_Decl:
	// Type declarations are T3.3. Nothing in them can be a mistake this task would find.
	case ast.Import_Named, ast.Import_Namespace, ast.Export_Named:
	// What a name refers to across modules is T3.5.

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
		check_expression(c, v.iterable)
		for_of_variable(c, v.declaration)
		check_statement(c, v.body)
	case ast.Switch:
		check_expression(c, v.value)
		for clause in v.cases {
			node := c.at.tree.nodes[clause].variant.(ast.Case)
			// Whether a case value can ever equal the subject is the comparability rule, which
			// arrives with narrowing in T3.4.
			check_expression(c, node.value)
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

// check_declarator types one `let` or `const` binding through its symbol.
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

// for_of_variable gives the loop variable of a `for...of` the error type without asking where it
// came from. Its type is the element type of the iterable, a string or an array, so it waits for
// T3.3 and T3.5. Until then it must not go through the usual path, which would see a `let` with
// neither an annotation nor an initializer and ask for one.
@(private)
for_of_variable :: proc(c: ^Checker, declaration: ast.Node_ID) {
	if declaration == ast.NO_NODE {
		return
	}
	node, is_var := c.at.tree.nodes[declaration].variant.(ast.Var_Decl)
	if !is_var {
		return
	}
	for declarator in node.declarators {
		if symbol := c.at.bound.node_symbols[declarator]; symbol != bind.NO_SYMBOL {
			c.symbol_types[{file = c.at.file, symbol = symbol}] = ERROR
		}
		set_type(c, declarator, ERROR)
	}
}

// check_return checks a `return` against the declared result, or records what it gives so that the
// result can be worked out from all of them together. A bare `return` gives nothing to that, as in
// tsc, so a body that returns no value at all is `void`.
//
// At the top level of a module there is no function and no declared result, so a stray `return`
// value is measured against the error type and passes. Whether it may stand there at all is a
// question about names and modules, which is T3.5.
@(private)
check_return :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Return) {
	if node.value == ast.NO_NODE {
		if c.at.returns == nil && !fits(c, UNDEFINED, c.at.result) {
			report_types(c, .Type_Mismatch, span_of(c, id), UNDEFINED, c.at.result)
		}
		return
	}

	value := check_expression(c, node.value)
	if c.at.returns != nil {
		append(c.at.returns, value)
		return
	}
	if !fits(c, value, c.at.result) {
		report_types(c, .Type_Mismatch, span_of(c, node.value), value, c.at.result)
	}
}
