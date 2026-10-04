package check

import "../ast"
import "../bind"

@(private)
check_statements :: proc(c: ^Checker, statements: []ast.Node_ID) {
	for id in statements {
		check_statement(c, id)
	}
}

// Module_Walk is how far the top level of one file has been walked: by check_file in order, and
// ahead of it by walk_above.
@(private)
Module_Walk :: struct {
	next:      int, // the first statement no walk has passed
	// A statement of the file is on the stack of the search, being walked or in a loop whose root is
	// still open, until close_component lets it go. walk_above walks nothing while one is above the
	// read, so there is at most one.
	held:      bool,
	statement: int,
	frame:     int,
}

// walk_module passes a declaration only once it has been read, so that walk_above from inside it
// still finds its declarators.
@(private)
walk_module :: proc(c: ^Checker, statements: []ast.Node_ID) {
	walk := &c.walks[c.at.file]
	for id, i in statements {
		if !runs_code(c, id) {
			check_statement(c, id)
			walk.next = max(walk.next, i + 1)
		} else if i >= walk.next {
			walk.next = i + 1
			walk_statement(c, id, i)
		}
	}
}

// walk_statement reads a top-level statement that runs code in a frame of the search, so that a
// read narrowed through it while it is held closes a loop with it from either end.
@(private)
walk_statement :: proc(c: ^Checker, id: ast.Node_ID, index: int) {
	walk := &c.walks[c.at.file]
	at, outer := enter_frame(c, {file = c.at.file})
	walk.held, walk.statement, walk.frame = true, index, at
	check_statement(c, id)
	leave_frame(c, at, outer, ERROR)
	if outer < 0 {
		check_deferred(c)
	}
}

// walk_above walks what a read at the top level of a module, or in an arrow made there, narrows
// through before the read does: the statements above it that run code and the declarators whose
// initializer adds to the flow. A name a function declares is never narrowed that far out.
//
// looped is a read in a loop with what stands above it, whose facts then depend on where the loop
// was entered. The walk stops there and leaves what is below to the module's own walk, which comes
// once the loop is closed, whichever end it was entered at.
@(private)
walk_above :: proc(c: ^Checker, read: ast.Node_ID) -> (looped: bool) {
	walk := &c.walks[c.at.file]
	module := c.at.tree.nodes[ast.ROOT].variant.(ast.Module)
	if walk.next >= len(module.statements) && !walk.held {
		return false
	}
	if declaring_function(c, read) != ast.NO_NODE {
		return false
	}
	nodes := c.at.tree.nodes
	start := nodes[read].span.start
	index := holding(nodes, module.statements, start)
	statement := module.statements[index]
	if _, is_function := nodes[statement].variant.(ast.Function_Decl); is_function {
		return false
	}
	if walk.held && walk.statement < index {
		reached(c, walk.frame)
		return true
	}

	previous := move_to(c, c.at.file)
	defer c.at = previous
	mark := mark_loops(c)
	for walk.next < index {
		i := walk.next
		walk.next = i + 1
		id := module.statements[i]
		if runs_code(c, id) {
			walk_statement(c, id, i)
			if closed_loop(c, mark) {
				return true
			}
		} else if node, is_var := nodes[id].variant.(ast.Var_Decl); is_var {
			if check_flowing(c, node.declarators, mark) {
				return true
			}
		}
	}
	if node, is_var := nodes[statement].variant.(ast.Var_Decl); is_var {
		return check_flowing(c, node.declarators[:holding(nodes, node.declarators, start)], mark)
	}
	return false
}

// Loop_Mark is where the search stood before walk_above walked anything. A frame left above it, or
// a lower frame the current one has come to reach, puts the read in a loop with what was walked.
@(private)
Loop_Mark :: struct {
	depth: int,
	low:   int,
}

@(private)
mark_loops :: proc(c: ^Checker) -> Loop_Mark {
	if c.search.current < 0 {
		return {depth = len(c.search.frames), low = -1}
	}
	return {depth = len(c.search.frames), low = c.search.frames[c.search.current].low}
}

@(private)
closed_loop :: proc(c: ^Checker, mark: Loop_Mark) -> bool {
	if len(c.search.frames) > mark.depth {
		return true
	}
	return c.search.current >= 0 && c.search.frames[c.search.current].low < mark.low
}

// holding is the index of the last of ids, which stand in source order, that starts at or before
// offset.
@(private)
holding :: proc(nodes: []ast.Node, ids: []ast.Node_ID, offset: i32) -> int {
	low, high := 0, len(ids)
	for low < high {
		middle := (low + high) / 2
		if nodes[ids[middle]].span.start <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low - 1
}

@(private)
check_flowing :: proc(c: ^Checker, declarators: []ast.Node_ID, mark: Loop_Mark) -> (looped: bool) {
	for id in declarators {
		init := c.at.tree.nodes[id].variant.(ast.Declarator).init
		if init != ast.NO_NODE && adds_flow(c, init) {
			check_declarator(c, id)
			if closed_loop(c, mark) {
				return true
			}
		}
	}
	return false
}

@(private)
runs_code :: proc(c: ^Checker, id: ast.Node_ID) -> bool {
	#partial switch _ in c.at.tree.nodes[id].variant {
	case ast.Var_Decl,
	     ast.Function_Decl,
	     ast.Interface_Decl,
	     ast.Type_Alias_Decl,
	     ast.Import_Named,
	     ast.Import_Namespace,
	     ast.Export_Named:
		return false
	}
	return true
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

// check_type_declaration reads a generic declaration once on its own, with the error type for each
// type parameter; a use reads it again quietly (enter_instance).
@(private)
check_type_declaration :: proc(c: ^Checker, id: ast.Node_ID) {
	symbol := c.at.bound.node_symbols[id]
	if symbol == bind.NO_SYMBOL {
		return // parse could not read the name and has reported it
	}
	ref := Symbol_Ref {
		file   = c.at.file,
		symbol = symbol,
	}
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Interface_Decl:
		if len(v.type_params) > 0 {
			body := c.at.tree.nodes[v.body].variant.(ast.Object_Type)
			object_fields(c, body.members)
			return
		}
	case ast.Type_Alias_Decl:
		if len(v.type_params) > 0 {
			search_alias(c, ref, nil)
			return
		}
	}
	named_type(c, ref, nil, c.at.bound.symbols[symbol].name)
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
	flow(c, value, c.at.result, span_of(c, node.value))
}
