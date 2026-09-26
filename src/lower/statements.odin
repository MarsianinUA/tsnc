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

// build_module_init opens by writing the zero of its type into every global of the module, which
// is the rule of the package doc.
@(private)
build_module_init :: proc(low: ^Lowering, file: source.File_ID, id: ir.Func_ID) {
	span := module_span(low, file)
	s := begin_function(low, file, id, ast.ROOT, bind.MODULE_SCOPE, nil, span)

	bound := &low.prog.bound[file]
	for symbol in bound.scopes[bind.MODULE_SCOPE].symbols {
		declaration := bound.symbols[symbol].declaration
		global, is_global := low.globals[{file, declaration}]
		if !is_global {
			continue
		}
		type := low.builder.globals[global].type
		zero: ir.Value_ID
		if low.closures[file].checked[symbol] && type == ir.STR {
			zero = ir.emit(&s.fb, ir.STR, ir.Const_Null{}, span) // the mark check_ready tests
		} else {
			zero = zero_value(&s, type, span)
		}
		ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = global, value = zero}, span)
		if flag, has_flag := low.ready[{file, declaration}]; has_flag {
			not_yet := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
			ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = flag, value = not_yet}, span)
		}
	}

	for statement in low.prog.trees[file].nodes[ast.ROOT].variant.(ast.Module).statements {
		lower_statement(&s, statement)
	}
	close_body(&s, span)
	end_function(&s)
}

// build_functions builds the declarations first and the arrows after, each in walk order.
@(private)
build_functions :: proc(low: ^Lowering, file: source.File_ID) {
	tree := &low.prog.trees[file]
	bound := &low.prog.bound[file]

	for id in low.closures[file].functions {
		func, is_declared := low.funcs[{file, id}]
		decl, is_decl := tree.nodes[id].variant.(ast.Function_Decl)
		if !is_declared || !is_decl {
			continue
		}
		span := tree.nodes[id].span
		s := begin_function(low, file, func, id, bound.node_scopes[decl.body], decl.params, span)
		lower_statement(&s, decl.body)
		close_body(&s, span)
		end_function(&s)
	}
	for id in low.closures[file].functions {
		func, is_declared := low.funcs[{file, id}]
		arrow, is_arrow := tree.nodes[id].variant.(ast.Arrow)
		if !is_declared || !is_arrow {
			continue
		}
		span := tree.nodes[id].span
		s := begin_function(low, file, func, id, bound.node_scopes[id], arrow.params, span)
		lower_arrow_body(&s, arrow.body, span)
		end_function(&s)
	}
}

// lower_arrow_body lowers the body of an arrow, a closure's or one inline_arrow puts in a loop, and
// leaves it. A block runs off its end as close_body says. An expression either does not come back,
// or the arrow returns it, one typed void as leave says.
@(private)
lower_arrow_body :: proc(s: ^Func_State, body: ast.Node_ID, span: source.Span) {
	if _, is_block := s.tree.nodes[body].variant.(ast.Block); is_block {
		lower_statement(s, body)
		close_body(s, span)
		return
	}
	switch {
	case s.typed.node_types[body] == check.NEVER:
		lower_effect(s, body)
		if !terminated(s) {
			ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		}
	case s.declared == ir.VOID:
		leave(s, lower_effect(s, body), span)
	case:
		value := lower_expression(s, body)
		given := s.typed.node_types[body]
		leave(s, flow_into(s, value, given, s.returns, s.declared, span), span)
	}
}

// inline_arrow lowers the arrow's body where the loop of map, filter, forEach or reduce calls it,
// with args, of the check types given, bound to its parameters. Its locals take their zero at every
// pass, as a new call's would. `break` and `continue` cannot leave an arrow, so the loops around the
// call are no targets inside it. Inside it, a `return` produces the arrow's own result and goes to
// the join of its Inline_Frame.
@(private)
inline_arrow :: proc(
	s: ^Func_State,
	callback: Callback,
	args: []ir.Value_ID,
	given: []check.Type_ID,
	span: source.Span,
) -> ir.Value_ID {
	arrow := s.tree.nodes[callback.arrow].variant.(ast.Arrow)
	zero_locals(s, s.bound.node_scopes[callback.arrow], span)
	for param, i in arrow.params {
		symbol := s.bound.node_symbols[param]
		if i >= len(args) || symbol == bind.NO_SYMBOL || is_refused(s, symbol) {
			continue
		}
		wanted := s.typed.node_types[param]
		value := flow_into(s, args[i], given[i], wanted, local_type(s, symbol), span)
		bind_local(s, symbol, value, span)
	}

	outer_loops, outer_declared, outer_returns := s.loops, s.declared, s.returns
	s.loops = make([dynamic]Loop_Frame, context.temp_allocator)
	s.declared, s.returns = callback.result, callback.function.result
	frame := Inline_Frame {
		join   = ir.add_block(&s.fb),
		edges  = make([dynamic]Edge, 0, 2, context.temp_allocator),
		values = make([dynamic]ir.Value_ID, 0, 2, context.temp_allocator),
		answer = callback.result,
	}
	if callback.result == ir.VOID && hands_on_value(s.low, s.file, callback.arrow) {
		frame.answer = ir.TAGGED
	}
	append(&s.inlines, frame)
	lower_arrow_body(s, arrow.body, span)
	frame = pop(&s.inlines)
	s.loops, s.declared, s.returns = outer_loops, outer_declared, outer_returns
	return join_values(s, frame.join, frame.edges[:], frame.values[:], frame.answer, span)
}

// close_body leaves a body whose end control still reaches, as running off it does: with nothing
// for a result of void, and with undefined for a tagged one. Any other result makes the end
// unreachable, since check reports a body that promises a value and can reach its end (T3024).
@(private)
close_body :: proc(s: ^Func_State, span: source.Span) {
	if terminated(s) {
		return
	}
	switch s.declared.kind {
	case .Void:
		leave(s, ir.NO_VALUE, span)
	case .Tagged:
		leave(s, ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span), span)
	case .F64, .Bool, .Str, .Closure, .Ref:
		ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
	}
}

// leave returns from the innermost inlined arrow, a jump to the join of its frame, or else from the
// function. A body typed void gives back what its value turned out to be (handed_on).
@(private)
leave :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) {
	if len(s.inlines) == 0 {
		leave_function(s, value, span)
		return
	}
	frame := &s.inlines[len(s.inlines) - 1]
	value := value
	if s.declared == ir.VOID {
		value = handed_on(s, value, frame.answer, span)
	}
	append(&frame.edges, here(s))
	append(&frame.values, value)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = frame.join}, span)
}

// leave_function returns what the function's own type gives as the result of its class, boxed into
// a wider class. Poison ends the block unreachable; it was reported.
@(private)
leave_function :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) {
	if s.result == ir.VOID {
		ir.emit(&s.fb, ir.VOID, ir.Return{value = ir.NO_VALUE}, span)
		return
	}
	returned: ir.Value_ID
	if s.declared == ir.VOID {
		returned = handed_on(s, value, s.result, span)
	} else {
		returned = coerce(s, value, s.result, span)
	}
	if returned == ir.NO_VALUE {
		ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		return
	}
	ir.emit(&s.fb, ir.VOID, ir.Return{value = returned}, span)
}

// handed_on is what a body typed void gives back where the caller keeps the answer as want: what a
// call in it answered, since Node returns that whatever the type says, or undefined where nothing
// came back. Nothing reads an answer wanted as VOID, so no undefined is made for it.
@(private)
handed_on :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	want: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	if value != ir.NO_VALUE || want == ir.VOID {
		return coerce(s, value, want, span)
	}
	undefined := ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
	return coerce(s, undefined, want, span)
}

// lower_statement first replaces a block the last terminator closed, so whatever follows a
// `return` still has somewhere to go.
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
		enter_scope(s, s.bound.node_scopes[id], span)
		for statement in v.statements {
			lower_statement(s, statement)
		}
	case ast.Expr_Stmt:
		lower_effect(s, v.expr)
		if s.typed.node_types[v.expr] == check.NEVER && !terminated(s) {
			// The expression does not come back: process.exit, or a function that never returns.
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
		lower_switch(s, id, v, span)
	case ast.Break:
		lower_jump(s, break_frame(s), false, span)
	case ast.Continue:
		lower_jump(s, continue_frame(s), true, span)
	case ast.Return:
		lower_return(s, v, span)
	case ast.For_Of:
		lower_for_of(s, id, v, span)
	}
	// Everything else declares a type, a name or nothing at all, and emits no code: an interface,
	// a type alias, an import, an export, a function declaration built on its own, an empty
	// statement, and a Bad node that parse already reported.
}

// lower_declarator leaves a binding with no initializer at the zero it was given when its body
// opened.
@(private)
lower_declarator :: proc(s: ^Func_State, id: ast.Node_ID) {
	node := s.tree.nodes[id].variant.(ast.Declarator)
	span := s.tree.nodes[id].span
	symbol := s.bound.node_symbols[id]
	global, is_global := s.low.globals[{s.file, id}]

	// A binding this slice has no room for was reported where it was declared. Its initializer is
	// dead, and walking it would name the same construct a second time.
	if !is_global && (local_at(s, symbol) < 0 || is_refused(s, symbol)) {
		return
	}
	type: ir.Type
	if is_global {
		type = s.low.builder.globals[global].type
	} else {
		type = local_type(s, symbol)
	}

	stored := ir.NO_VALUE
	if node.init != ast.NO_NODE {
		value := lower_expression(s, node.init)
		if type == ir.VOID {
			return // a binding typed `never` holds nothing (store_place)
		}
		given, wanted := s.typed.node_types[node.init], s.typed.node_types[id]
		stored = flow_into(s, value, given, wanted, type, span)
	} else if s.low.closures[s.file].checked[symbol] && type == ir.STR {
		// No initializer leaves the zero, the empty cell, in place of the mark of check_ready.
		stored = zero_value(s, ir.STR, span)
	}
	if !is_global {
		write_local(s, symbol, stored, span)
	} else if stored != ir.NO_VALUE {
		ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = global, value = stored}, span)
	}
	if stored != ir.NO_VALUE || node.init == ast.NO_NODE {
		mark_ready(s, symbol, span)
	}
}

// lower_return inside an inlined arrow ends the arrow and not the function around it (leave), a bare
// one as well.
@(private)
lower_return :: proc(s: ^Func_State, node: ast.Return, span: source.Span) {
	if node.value == ast.NO_NODE {
		close_body(s, span)
		return
	}

	value := lower_expression(s, node.value)
	if s.declared != ir.VOID {
		given := s.typed.node_types[node.value]
		value = flow_into(s, value, given, s.returns, s.declared, span)
	}
	leave(s, value, span)
}

// lower_jump ignores a missing frame: bind has already reported a `break` or `continue` that leaves
// nothing, so the program will not be built.
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

// branch_condition puts a constant in place of a condition this build cannot compile, which was
// reported already: it keeps the shape of the program, so the statements inside are still walked
// and everything wrong in them is still named.
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

@(private)
enter_loop :: proc(
	s: ^Func_State,
	blocks: Loop_Blocks,
	assigned: []int,
	span: source.Span,
) -> []ir.Value_ID {
	from := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.header}, span)
	return open_header(s, blocks.header, assigned, from, span)
}

// open_latch answers false when nothing reaches the latch, which leaves the header with the one
// edge that entered it.
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

// close_latch renews the boxed `let` bindings of a `for` header ahead of the update, once every
// `continue` has joined, so the next pass has bindings of its own.
@(private)
close_latch :: proc(
	s: ^Func_State,
	blocks: Loop_Blocks,
	frame: Loop_Frame,
	phis: []ir.Value_ID,
	assigned: []int,
	renewed: []bind.Symbol_ID,
	update: ast.Node_ID,
	span: source.Span,
) {
	if !open_latch(s, blocks.latch, frame, span) {
		return
	}
	renew_bindings(s, renewed, span)
	if update != ast.NO_NODE {
		lower_effect(s, update)
	}
	back := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.header}, span)
	patch_header(s, phis, assigned, back)
}

@(private)
lower_while :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.While, span: source.Span) {
	lower_for(s, id, ast.For{condition = node.condition, body = node.body}, span)
}

// lower_for gives a `let` of the header that a closure shares a new binding for every pass, as
// ECMAScript's CreatePerIterationEnvironment does: once after the init, so that a closure the init
// made keeps the first binding, and again at the latch. lower_while shares this with an id that
// opens no scope.
@(private)
lower_for :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.For, span: source.Span) {
	renewed: []bind.Symbol_ID
	_, is_for := s.tree.nodes[id].variant.(ast.For)
	if is_for {
		enter_scope(s, s.bound.node_scopes[id], span)
	}
	if node.init != ast.NO_NODE {
		if _, is_declaration := s.tree.nodes[node.init].variant.(ast.Var_Decl); is_declaration {
			lower_statement(s, node.init)
		} else {
			lower_effect(s, node.init)
		}
	}
	if is_for {
		renewed = boxed_lets(s, s.bound.node_scopes[id])
		renew_bindings(s, renewed, span)
	}

	// The box of a renewed binding changes from one pass to the next.
	assigned := assigned_locals(s, id, renewed)
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

	close_latch(s, blocks, frame, phis, assigned, renewed, node.update, span)
	if node.condition != ast.NO_NODE {
		leave_loop(s, blocks.exit, leaving, frame, span)
	} else {
		open_join(s, blocks.exit, frame.breaks[:], span)
	}
}

// boxed_lets lists the `let` bindings of a scope that live in a box, in symbol order.
@(private)
boxed_lets :: proc(s: ^Func_State, scope: bind.Scope_ID) -> []bind.Symbol_ID {
	found := make([dynamic]bind.Symbol_ID, 0, 2, context.temp_allocator)
	for symbol in s.bound.scopes[scope].symbols {
		entry := s.bound.symbols[symbol]
		if entry.kind == .Let && s.low.closures[s.file].boxed[symbol] && !is_refused(s, symbol) {
			append(&found, symbol)
		}
	}
	return found[:]
}

// renew_bindings moves each variable into a box of its own, holding the value it has now.
@(private)
renew_bindings :: proc(s: ^Func_State, symbols: []bind.Symbol_ID, span: source.Span) {
	for symbol in symbols {
		bind_local(s, symbol, read_local(s, symbol, span), span)
	}
}

@(private)
lower_do_while :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Do_While, span: source.Span) {
	assigned := assigned_locals(s, id)
	blocks := open_loop(s)
	phis := enter_loop(s, blocks, assigned, span)

	// The body is the header itself: a do-while runs it before it ever tests anything.
	push_frame(s, blocks.latch, blocks.exit)
	lower_statement(s, node.body)
	frame := pop(&s.loops)

	leaving := Edge {
		block = ir.NO_BLOCK,
	}
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
	if leaving.block != ir.NO_BLOCK {
		append(&exits, leaving)
	}
	append(&exits, ..frame.breaks[:])
	open_join(s, blocks.exit, exits[:], span)
}

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
lower_switch :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.Switch, span: source.Span) {
	subject := switch_subject(s, node.value)
	// Before the first test: a case test may call a function declared in one of the cases.
	enter_scope(s, s.bound.node_scopes[id], span)
	bodies := make([]ir.Block_ID, len(node.cases), context.temp_allocator)
	incoming := make([][dynamic]Edge, len(node.cases), context.temp_allocator)
	for i in 0 ..< len(node.cases) {
		bodies[i] = ir.add_block(&s.fb)
		incoming[i] = make([dynamic]Edge, 0, 2, context.temp_allocator)
	}
	exit := ir.add_block(&s.fb)

	fallback := exit
	otherwise := -1 // the `default` case, wherever in the list it stands
	for case_id, i in node.cases {
		value := s.tree.nodes[case_id].variant.(ast.Case).value
		if value == ast.NO_NODE {
			fallback = bodies[i]
			otherwise = i
			continue
		}
		test := case_test(s, &subject, value)
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
	for case_id, i in node.cases {
		if !open_join(s, bodies[i], incoming[i][:], span) {
			continue
		}
		for statement in s.tree.nodes[case_id].variant.(ast.Case).statements {
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

// case_test stays quiet about a subject this build cannot compare: the expression itself reported
// it.
@(private)
case_test :: proc(s: ^Func_State, subject: ^Switch_Subject, value: ast.Node_ID) -> ir.Value_ID {
	span := s.tree.nodes[value].span
	if subject.of_tagged {
		if test, matched := typeof_case_test(s, subject, value); matched {
			return test
		}
	}
	other := lower_expression(s, value)
	if subject.value != ir.NO_VALUE && other != ir.NO_VALUE {
		values := [2]ir.Value_ID{subject.value, other}
		if test := lower_compare(s, .Equal, values, span); test != ir.NO_VALUE {
			return test
		}
	}
	return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
}

// lower_for_of reads the length again before every step, as the iterator does, so a body that
// pushes is walked to the new end. A string is walked by code point: a step takes a surrogate pair
// whole and moves the index by the length of what it took.
@(private)
lower_for_of :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.For_Of, span: source.Span) {
	iterable := lower_expression(s, node.iterable)
	declaration := s.tree.nodes[node.declaration].variant.(ast.Var_Decl)
	symbol := s.bound.node_symbols[declaration.declarators[0]]
	element, is_array := element_type(s, s.typed.node_types[node.iterable])
	is_string := iterable != ir.NO_VALUE && value_type(s, iterable) == ir.STR
	is_array &&= iterable != ir.NO_VALUE && value_type(s, iterable).kind == .Ref
	if iterable != ir.NO_VALUE && !is_string && !is_array {
		// check loops over an array or a string, and nothing else.
		later(s, span, "looping over this value")
	}
	if !is_string && !is_array || symbol == bind.NO_SYMBOL || is_refused(s, symbol) {
		// Whatever is wrong was reported; the body is still walked for what it holds.
		lower_statement(s, node.body)
		return
	}

	assigned := assigned_locals(s, id)
	blocks := open_loop(s)
	start := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	entry := s.fb.current
	phis := enter_loop(s, blocks, assigned, span)
	index := ir.phi(&s.fb, ir.F64, span)
	ir.phi_incoming(&s.fb, index, entry, start)
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = iterable}, span)
	more := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Less, left = index, right = length}, span)
	leaving := here(s)
	branch := ir.Branch {
		condition  = more,
		then_block = blocks.body,
		else_block = blocks.exit,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, blocks.body)
	checked := bounds_check(s, iterable, index, span)
	step, piece: ir.Value_ID
	if is_string {
		call := ir.Call_Runtime {
			export = .String_Code_Point_At,
			args   = {iterable, checked},
		}
		piece = ir.emit(&s.fb, ir.STR, call, span)
		step = ir.emit(&s.fb, ir.F64, ir.Length{value = piece}, span)
	} else {
		load := ir.Element_Load {
			array = iterable,
			index = checked,
		}
		piece = ir.emit(&s.fb, element, load, span)
		step = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 1}, span)
	}
	next := ir.emit(&s.fb, ir.F64, ir.Binary{op = .Add, left = index, right = step}, span)
	bind_local(s, symbol, coerce(s, piece, local_type(s, symbol), span), span)

	push_frame(s, blocks.latch, blocks.exit)
	lower_statement(s, node.body)
	frame := pop(&s.loops)
	if open_latch(s, blocks.latch, frame, span) {
		back := here(s)
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.header}, span)
		patch_header(s, phis, assigned, back)
		ir.phi_incoming(&s.fb, index, back.block, next)
	}
	leave_loop(s, blocks.exit, leaving, frame, span)
}
