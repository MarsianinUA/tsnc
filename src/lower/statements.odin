package lower

import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../source"

/*
Statements, and the two kinds of body that hold them.

Control flow is built out of blocks and phis. Every loop has the same four blocks: a header holding
the phis of the variables the loop writes, a body, a latch where the back edge and every `continue`
come together, and an exit where the loop's own end and every `break` do. A `switch` is a chain of
comparisons followed by the case bodies in source order, each one a join of its own test and of the
case before it that fell through.

Statements after a terminator get a block of their own, because the builder closes a block on its
terminator and a `return` in the middle of one is ordinary TypeScript.
*/

// build_module_init builds the top-level code of one module. It opens by writing the zero of its
// type into every global of the module, which is the rule of the package doc.
@(private)
build_module_init :: proc(low: ^Lowering, file: source.File_ID, id: ir.Func_ID) {
	span := module_span(low, file)
	s := begin_function(low, file, id, bind.MODULE_SCOPE, nil, ir.VOID, span)

	bound := &low.prog.bound[file]
	for symbol in bound.scopes[bind.MODULE_SCOPE].symbols {
		declaration := bound.symbols[symbol].declaration
		global, is_global := low.globals[{file, declaration}]
		if !is_global {
			continue
		}
		zero := zero_value(&s, low.builder.globals[global].type, span)
		ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = global, value = zero}, span)
	}

	for statement in low.prog.trees[file].nodes[ast.ROOT].variant.(ast.Module).statements {
		lower_statement(&s, statement)
	}
	close_body(&s, span)
	ir.end_func(&s.fb)
}

// build_functions builds the body of every function declaration the module declared an IR row for.
@(private)
build_functions :: proc(low: ^Lowering, file: source.File_ID) {
	tree := &low.prog.trees[file]
	bound := &low.prog.bound[file]

	for id in function_decls(tree) {
		func, is_declared := low.funcs[{file, id}]
		if !is_declared {
			continue
		}
		decl := tree.nodes[id].variant.(ast.Function_Decl)
		span := tree.nodes[id].span
		result := low.builder.funcs[func].result
		scope := bound.node_scopes[decl.body]
		s := begin_function(low, file, func, scope, decl.params, result, span)
		lower_statement(&s, decl.body)
		close_body(&s, span)
		ir.end_func(&s.fb)
	}
}

// close_body ends a body whose last statement was not a `return`. A function that promises a value
// and can still reach its end is one check reports, so the IR here only has to stay well formed.
@(private)
close_body :: proc(s: ^Func_State, span: source.Span) {
	if terminated(s) {
		return
	}
	switch s.result.kind {
	case .Void:
		ir.emit(&s.fb, ir.VOID, ir.Return{value = ir.NO_VALUE}, span)
	case .Tagged:
		value := ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
		ir.emit(&s.fb, ir.VOID, ir.Return{value = value}, span)
	case .F64, .Bool, .Str, .Closure, .Ref:
		ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
	}
}

// lower_statement builds one statement. A block the last terminator closed is replaced first, so
// whatever follows a `return` still has somewhere to go.
@(private)
lower_statement :: proc(s: ^Func_State, id: ast.Node_ID) {
	if id == ast.NO_NODE {
		return
	}
	if terminated(s) {
		ir.use_block(&s.fb, ir.add_block(&s.fb))
	}

	span := s.tree.nodes[id].span
	#partial switch v in s.tree.nodes[id].variant {
	case ast.Block:
		for statement in v.statements {
			lower_statement(s, statement)
		}
	case ast.Expr_Stmt:
		lower_expression(s, v.expr)
		if s.typed.node_types[v.expr] == check.NEVER && !terminated(s) {
			// The call does not come back: process.exit is the only one in this slice.
			ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		}
	case ast.Var_Decl:
		for declarator in v.declarators {
			lower_declarator(s, declarator)
		}
	case ast.If:
		lower_if(s, v, span)
	case ast.While:
		lower_while(s, id, v, span)
	case ast.Do_While:
		lower_do_while(s, id, v, span)
	case ast.For:
		lower_for(s, id, v, span)
	case ast.Switch:
		lower_switch(s, v, span)
	case ast.Break:
		lower_jump(s, break_frame(s), false, span)
	case ast.Continue:
		lower_jump(s, continue_frame(s), true, span)
	case ast.Return:
		lower_return(s, v, span)
	case ast.For_Of:
		later(s, span, "`for...of`")
	}
	// Everything else declares a type, a name or nothing at all, and emits no code: an interface,
	// a type alias, an import, an export, a function declaration built on its own, an empty
	// statement, and a Bad node that parse already reported.
}

// lower_declarator writes the initial value of a binding. A binding with no initializer keeps the
// zero it was given when its body opened.
@(private)
lower_declarator :: proc(s: ^Func_State, id: ast.Node_ID) {
	node := s.tree.nodes[id].variant.(ast.Declarator)
	span := s.tree.nodes[id].span
	symbol := s.bound.node_symbols[id]
	global, is_global := s.low.globals[{s.file, id}]

	// A binding this slice has no room for was reported where it was declared. Its initializer is
	// dead, and walking it would name the same construct a second time.
	if !is_global && (symbol == bind.NO_SYMBOL || s.locals[symbol] == ir.NO_VALUE) {
		return
	}
	if node.init == ast.NO_NODE {
		return
	}

	value := lower_expression(s, node.init)
	if value == ir.NO_VALUE {
		return
	}
	if is_global {
		stored := coerce(s, value, s.low.builder.globals[global].type, span)
		if stored != ir.NO_VALUE {
			ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = global, value = stored}, span)
		}
		return
	}
	stored := coerce(s, value, value_type(s, s.locals[symbol]), span)
	if stored != ir.NO_VALUE {
		s.locals[symbol] = stored
	}
}

@(private)
lower_return :: proc(s: ^Func_State, node: ast.Return, span: source.Span) {
	if node.value == ast.NO_NODE {
		close_body(s, span)
		return
	}

	value := lower_expression(s, node.value)
	if s.result == ir.VOID {
		ir.emit(&s.fb, ir.VOID, ir.Return{value = ir.NO_VALUE}, span)
		return
	}
	returned := coerce(s, value, s.result, span)
	if returned == ir.NO_VALUE {
		ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		return
	}
	ir.emit(&s.fb, ir.VOID, ir.Return{value = returned}, span)
}

// lower_jump is `break` and `continue`. bind has already reported one that leaves nothing, so a
// missing frame here is a program that will not be built.
@(private)
lower_jump :: proc(s: ^Func_State, frame: ^Loop_Frame, is_continue: bool, span: source.Span) {
	if frame == nil {
		return
	}
	edge := here(s)
	if is_continue {
		append(&frame.continues, edge)
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = frame.latch}, span)
		return
	}
	append(&frame.breaks, edge)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = frame.exit}, span)
}

// branch_condition is the boolean a statement branches on. A condition this build cannot compile
// was reported already; a constant in its place keeps the shape of the program, so the statements
// inside are still walked and everything wrong in them is still named.
@(private)
branch_condition :: proc(s: ^Func_State, id: ast.Node_ID, span: source.Span) -> ir.Value_ID {
	if id == ast.NO_NODE {
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
	}
	test := lower_condition(s, id)
	if test != ir.NO_VALUE {
		return test
	}
	return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
}

@(private)
lower_if :: proc(s: ^Func_State, node: ast.If, span: source.Span) {
	test := branch_condition(s, node.condition, span)
	then_block := ir.add_block(&s.fb)
	else_block := ir.add_block(&s.fb) if node.else_branch != ast.NO_NODE else ir.NO_BLOCK
	join := ir.add_block(&s.fb)

	entering := here(s)
	branch := ir.Branch {
		condition  = test,
		then_block = then_block,
		else_block = else_block if else_block != ir.NO_BLOCK else join,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	ir.use_block(&s.fb, then_block)
	copy(s.locals, entering.values)
	lower_statement(s, node.then_branch)
	if !terminated(s) {
		append(&edges, here(s))
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	}

	if else_block == ir.NO_BLOCK {
		append(&edges, entering)
	} else {
		ir.use_block(&s.fb, else_block)
		copy(s.locals, entering.values)
		lower_statement(s, node.else_branch)
		if !terminated(s) {
			append(&edges, here(s))
			ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
		}
	}
	open_join(s, join, edges[:], span)
}

// Loop_Blocks are the four blocks every loop is built from.
@(private)
Loop_Blocks :: struct {
	header: ir.Block_ID,
	body:   ir.Block_ID,
	latch:  ir.Block_ID,
	exit:   ir.Block_ID,
}

@(private)
open_loop :: proc(s: ^Func_State) -> Loop_Blocks {
	return {
		header = ir.add_block(&s.fb),
		body = ir.add_block(&s.fb),
		latch = ir.add_block(&s.fb),
		exit = ir.add_block(&s.fb),
	}
}

// enter_loop jumps into the header and gives it the phis of everything the loop writes.
@(private)
enter_loop :: proc(
	s: ^Func_State,
	blocks: Loop_Blocks,
	assigned: []bind.Symbol_ID,
	span: source.Span,
) -> []ir.Value_ID {
	from := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.header}, span)
	return open_header(s, blocks.header, assigned, from, span)
}

// open_latch joins the end of the body with every `continue`. It answers false when nothing reaches
// the latch, which leaves the header with the one edge that entered it.
@(private)
open_latch :: proc(
	s: ^Func_State,
	latch: ir.Block_ID,
	frame: Loop_Frame,
	span: source.Span,
) -> bool {
	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	if !terminated(s) {
		append(&edges, here(s))
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = latch}, span)
	}
	append(&edges, ..frame.continues[:])
	return open_join(s, latch, edges[:], span)
}

// close_latch runs the update of a `for` and takes the back edge to the header.
@(private)
close_latch :: proc(
	s: ^Func_State,
	blocks: Loop_Blocks,
	frame: Loop_Frame,
	phis: []ir.Value_ID,
	assigned: []bind.Symbol_ID,
	update: ast.Node_ID,
	span: source.Span,
) {
	if !open_latch(s, blocks.latch, frame, span) {
		return
	}
	if update != ast.NO_NODE {
		lower_expression(s, update)
	}
	back := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.header}, span)
	patch_header(s, phis, assigned, back)
}

// lower_while is a `for` with only a condition, which is what a `while` is.
@(private)
lower_while :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.While, span: source.Span) {
	lower_for(s, id, ast.For{condition = node.condition, body = node.body}, span)
}

@(private)
lower_for :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.For, span: source.Span) {
	if node.init != ast.NO_NODE {
		if _, is_declaration := s.tree.nodes[node.init].variant.(ast.Var_Decl); is_declaration {
			lower_statement(s, node.init)
		} else {
			lower_expression(s, node.init)
		}
	}

	assigned := assigned_symbols(s, id)
	blocks := open_loop(s)
	phis := enter_loop(s, blocks, assigned, span)

	leaving := Edge{}
	if node.condition != ast.NO_NODE {
		test := branch_condition(s, node.condition, span)
		leaving = here(s)
		branch := ir.Branch {
			condition  = test,
			then_block = blocks.body,
			else_block = blocks.exit,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
	} else {
		// `for (;;)` leaves only through a `break`.
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.body}, span)
	}

	push_frame(s, blocks.latch, blocks.exit)
	ir.use_block(&s.fb, blocks.body)
	if node.condition != ast.NO_NODE {
		copy(s.locals, leaving.values)
	}
	lower_statement(s, node.body)
	frame := pop(&s.loops)

	close_latch(s, blocks, frame, phis, assigned, node.update, span)
	if node.condition != ast.NO_NODE {
		leave_loop(s, blocks.exit, leaving, frame, span)
	} else {
		open_join(s, blocks.exit, frame.breaks[:], span)
	}
}

@(private)
lower_do_while :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Do_While, span: source.Span) {
	assigned := assigned_symbols(s, id)
	blocks := open_loop(s)
	phis := enter_loop(s, blocks, assigned, span)

	// The body is the header itself: a do-while runs it before it ever tests anything.
	push_frame(s, blocks.latch, blocks.exit)
	lower_statement(s, node.body)
	frame := pop(&s.loops)

	leaving := Edge{}
	if open_latch(s, blocks.latch, frame, span) {
		test := branch_condition(s, node.condition, span)
		leaving = here(s)
		branch := ir.Branch {
			condition  = test,
			then_block = blocks.header,
			else_block = blocks.exit,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
		patch_header(s, phis, assigned, leaving)
	}

	// The body block the loop opened is never jumped to: the header holds the body itself. It is
	// filled before the exit, so that the builder is left standing wherever the exit leaves it.
	ir.use_block(&s.fb, blocks.body)
	ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)

	exits := make([dynamic]Edge, 0, 2, context.temp_allocator)
	if leaving.values != nil {
		append(&exits, leaving)
	}
	append(&exits, ..frame.breaks[:])
	open_join(s, blocks.exit, exits[:], span)
}

// leave_loop opens the exit of a loop: the edge the condition took out of it, and every `break`.
@(private)
leave_loop :: proc(
	s: ^Func_State,
	exit: ir.Block_ID,
	leaving: Edge,
	frame: Loop_Frame,
	span: source.Span,
) {
	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	append(&edges, leaving)
	append(&edges, ..frame.breaks[:])
	open_join(s, exit, edges[:], span)
}

// lower_switch builds the comparisons first and the case bodies after, in source order. A body is a
// join of the test that picked it and of the case above it, when that one fell through.
@(private)
lower_switch :: proc(s: ^Func_State, node: ast.Switch, span: source.Span) {
	subject := lower_expression(s, node.value)
	bodies := make([]ir.Block_ID, len(node.cases), context.temp_allocator)
	incoming := make([][dynamic]Edge, len(node.cases), context.temp_allocator)
	for i in 0 ..< len(node.cases) {
		bodies[i] = ir.add_block(&s.fb)
		incoming[i] = make([dynamic]Edge, 0, 2, context.temp_allocator)
	}
	exit := ir.add_block(&s.fb)

	fallback := exit
	otherwise := -1 // the `default` case, wherever in the list it stands
	for id, i in node.cases {
		value := s.tree.nodes[id].variant.(ast.Case).value
		if value == ast.NO_NODE {
			fallback = bodies[i]
			otherwise = i
			continue
		}
		test := case_test(s, subject, value)
		next := ir.add_block(&s.fb)
		append(&incoming[i], here(s))
		branch := ir.Branch {
			condition  = test,
			then_block = bodies[i],
			else_block = next,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
		ir.use_block(&s.fb, next)
	}

	exits := make([dynamic]Edge, 0, 2, context.temp_allocator)
	chain := here(s)
	if otherwise < 0 {
		append(&exits, chain)
	} else {
		append(&incoming[otherwise], chain)
	}
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = fallback}, span)

	push_frame(s, ir.NO_BLOCK, exit)
	for id, i in node.cases {
		if !open_join(s, bodies[i], incoming[i][:], span) {
			continue
		}
		for statement in s.tree.nodes[id].variant.(ast.Case).statements {
			lower_statement(s, statement)
		}
		if terminated(s) {
			continue
		}
		edge := here(s)
		if i + 1 < len(node.cases) {
			append(&incoming[i + 1], edge)
			ir.emit(&s.fb, ir.VOID, ir.Jump{target = bodies[i + 1]}, span)
		} else {
			append(&exits, edge)
			ir.emit(&s.fb, ir.VOID, ir.Jump{target = exit}, span)
		}
	}
	frame := pop(&s.loops)

	append(&exits, ..frame.breaks[:])
	open_join(s, exit, exits[:], span)
}

// case_test compares the value of the switch with the value of one case. A subject this build
// cannot compare was reported by the expression itself.
@(private)
case_test :: proc(s: ^Func_State, subject: ir.Value_ID, value: ast.Node_ID) -> ir.Value_ID {
	span := s.tree.nodes[value].span
	other := lower_expression(s, value)
	if subject != ir.NO_VALUE && other != ir.NO_VALUE {
		if test := lower_compare(s, .Equal, subject, other, span); test != ir.NO_VALUE {
			return test
		}
	}
	return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
}
