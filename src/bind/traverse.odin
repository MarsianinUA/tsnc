package bind

import "../ast"

// bind_node binds one node: the names it uses, the scope it opens and its place in the flow graph.
// It is the one exhaustive switch over the shapes of ast, and every case binds its children in
// source order. The names a scope declares are already in place: declare_statements runs first.
@(private)
bind_node :: proc(b: ^Binder, id: ast.Node_ID) {
	if id == ast.NO_NODE {
		return
	}
	switch v in b.tree.nodes[id].variant {
	// Nothing to bind: a literal, a name that the scopes or the module tables already hold, or a
	// case, which bind_switch binds in its own order.
	case ast.Bad,
	     ast.Empty,
	     ast.Number_Literal,
	     ast.String_Literal,
	     ast.Bool_Literal,
	     ast.Null_Literal,
	     ast.Keyword_Type,
	     ast.Literal_Type,
	     ast.Type_Param,
	     ast.Specifier,
	     ast.Case,
	     ast.Import_Named,
	     ast.Import_Namespace,
	     ast.Export_Named:
	case ast.Module:
		unreachable() // bind_file binds the root, and no node has it as a child

	// Declarations.
	case ast.Var_Decl:
		for declarator in v.declarators {
			bind_node(b, declarator)
		}
	case ast.Declarator:
		bind_node(b, v.type)
		bind_node(b, v.init)
		if v.init != ast.NO_NODE {
			add_assignment(b, id)
		}
	case ast.Function_Decl:
		bind_function(b, id, v.type_params, v.params, v.return_type, v.body, UNREACHABLE)
	case ast.Param:
		bind_node(b, v.type)
	case ast.Interface_Decl:
		previous := open_type_scope(b, id, v.type_params)
		bind_node(b, v.body)
		close_scope(b, previous)
	case ast.Type_Alias_Decl:
		previous := open_type_scope(b, id, v.type_params)
		bind_node(b, v.type)
		close_scope(b, previous)

	// Statements.
	case ast.Block:
		previous := open_scope(b, .Block, id)
		declare_statements(b, v.statements)
		bind_statements(b, v.statements)
		close_scope(b, previous)
	case ast.Expr_Stmt:
		bind_node(b, v.expr)
		bind_call_statement(b, v.expr)
	case ast.If:
		bind_if(b, v)
	case ast.Switch:
		bind_switch(b, id, v)
	case ast.For:
		bind_for(b, id, v)
	case ast.For_Of:
		bind_for_of(b, id, v)
	case ast.While:
		bind_while(b, v)
	case ast.Do_While:
		bind_do_while(b, v)
	case ast.Break:
		bind_jump(b, b.break_target)
	case ast.Continue:
		bind_jump(b, b.continue_target)
	case ast.Return:
		bind_node(b, v.value)
		b.current = UNREACHABLE

	// Expressions.
	case ast.Ident:
		b.node_flow[id] = b.current
		resolve(b, id, ast.Name{text = v.name, span = b.tree.nodes[id].span}, .Value)
	case ast.Template:
		for expression in v.expressions {
			bind_node(b, expression)
		}
	case ast.Array_Literal:
		for element in v.elements {
			bind_node(b, element)
		}
	case ast.Object_Literal:
		for property in v.properties {
			bind_node(b, property)
		}
	case ast.Property:
		bind_node(b, v.value)
	case ast.Arrow:
		bind_function(b, id, nil, v.params, v.return_type, v.body, b.current)
	case ast.Unary:
		bind_node(b, v.operand)
	case ast.Update:
		bind_node(b, v.operand)
		mark_assigned(b, v.operand)
		if is_narrowable(b, v.operand) {
			add_assignment(b, id)
		}
	case ast.Binary:
		if _, is_logical := logical_op(v.op); is_logical {
			bind_logical_value(b, id)
		} else {
			bind_node(b, v.left)
			bind_node(b, v.right)
		}
	case ast.Assign:
		if _, is_logical := logical_assign_op(v.op); is_logical {
			bind_logical_value(b, id)
		} else {
			bind_node(b, v.target)
			bind_node(b, v.value)
			mark_assigned(b, v.target)
			if is_narrowable(b, v.target) {
				add_assignment(b, id)
			}
		}
	case ast.Conditional:
		bind_conditional(b, v)
	case ast.Call:
		bind_node(b, v.callee)
		for argument in v.args {
			bind_node(b, argument)
		}
	case ast.Member:
		b.node_flow[id] = b.current
		bind_node(b, v.object)
	case ast.Index:
		b.node_flow[id] = b.current
		bind_node(b, v.object)
		bind_node(b, v.index)
	case ast.As:
		bind_node(b, v.expr)
		bind_node(b, v.type)
	case ast.Non_Null:
		bind_node(b, v.expr)

	// Types.
	case ast.Type_Ref:
		bind_type_ref(b, id, v)
		for argument in v.args {
			bind_node(b, argument)
		}
	case ast.Array_Type:
		bind_node(b, v.element)
	case ast.Union_Type:
		for member in v.members {
			bind_node(b, member)
		}
	case ast.Function_Type:
		previous := open_type_scope(b, id, v.type_params)
		for param in v.params {
			bind_node(b, param)
		}
		bind_node(b, v.return_type)
		close_scope(b, previous)
	case ast.Object_Type:
		for member in v.members {
			bind_node(b, member)
		}
	case ast.Property_Signature:
		bind_node(b, v.type)
	}
}

@(private)
bind_statements :: proc(b: ^Binder, statements: []ast.Node_ID) {
	for id in statements {
		bind_node(b, id)
	}
}

// bind_function binds a function declaration or an arrow: its own scope holds the type
// parameters, the parameters and the names of its body, and its flow graph stands on its own.
// outer is the flow where an arrow is created, so that check keeps a narrowing inside it, and
// UNREACHABLE for a function declaration, which is hoisted and may run at any point.
@(private)
bind_function :: proc(
	b: ^Binder,
	id: ast.Node_ID,
	type_params: []ast.Node_ID,
	params: []ast.Node_ID,
	return_type: ast.Node_ID,
	body: ast.Node_ID,
	outer: Flow_ID,
) {
	previous_scope := open_scope(b, .Function, id)
	previous_function := b.function
	previous_flow := b.current
	previous_effects := b.has_flow_effects
	previous_break, previous_continue := b.break_target, b.continue_target
	b.function = b.scope
	b.break_target, b.continue_target = NO_LABEL, NO_LABEL

	declare_type_params(b, type_params)
	for param in params {
		parameter := b.tree.nodes[param].variant.(ast.Param)
		declare(b, parameter.name, .Param, param)
	}
	for param in params {
		bind_node(b, param) // the parameter's type annotation
	}
	bind_node(b, return_type)

	if body != ast.NO_NODE {
		b.current = add_flow(b, Flow_Start{function = id, outer = outer})
		block, is_block := b.tree.nodes[body].variant.(ast.Block)
		if is_block {
			// The body shares the function's scope: a parameter and a `let` beside it collide.
			b.node_scopes[body] = b.scope
			declare_statements(b, block.statements)
			bind_statements(b, block.statements)
			b.node_flow[body] = b.current
		} else {
			bind_node(b, body) // `x => x * 2`, which always returns
		}
	}

	// What the body wrote stays inside it: a call in a closure is not a write where it is created.
	b.current = previous_flow
	b.has_flow_effects = previous_effects
	b.break_target, b.continue_target = previous_break, previous_continue
	b.function = previous_function
	close_scope(b, previous_scope)
}

// open_type_scope opens the scope of a declaration's type parameters, and nothing when it has
// none.
@(private)
open_type_scope :: proc(
	b: ^Binder,
	id: ast.Node_ID,
	type_params: []ast.Node_ID,
) -> (
	previous: Scope_ID,
) {
	if len(type_params) == 0 {
		return b.scope
	}
	previous = open_scope(b, .Type, id)
	declare_type_params(b, type_params)
	return previous
}

@(private)
declare_type_params :: proc(b: ^Binder, type_params: []ast.Node_ID) {
	for id in type_params {
		type_param := b.tree.nodes[id].variant.(ast.Type_Param)
		declare(b, type_param.name, .Type_Param, id)
	}
}

// bind_type_ref resolves the name of a type. In `m.T` only `m` is a name of this file: check looks
// T up among the exports of the module m stands for.
@(private)
bind_type_ref :: proc(b: ^Binder, id: ast.Node_ID, node: ast.Type_Ref) {
	if node.qualifier.text != "" {
		resolve(b, id, node.qualifier, .Value)
		return
	}
	resolve(b, id, node.name, .Type)
}

// Control statements.

@(private)
bind_if :: proc(b: ^Binder, node: ast.If) {
	then_label := new_branch_label(b)
	else_label := new_branch_label(b)
	post_label := new_branch_label(b)
	bind_condition(b, node.condition, then_label, else_label)
	b.current = finish_label(b, then_label)
	bind_node(b, node.then_branch)
	add_antecedent(b, post_label, b.current)
	b.current = finish_label(b, else_label)
	bind_node(b, node.else_branch)
	add_antecedent(b, post_label, b.current)
	b.current = finish_label(b, post_label)
}

@(private)
bind_while :: proc(b: ^Binder, node: ast.While) {
	loop_label := new_loop_label(b)
	body_label := new_branch_label(b)
	post_label := new_branch_label(b)
	enter_loop(b, loop_label)
	bind_condition(b, node.condition, body_label, post_label)
	b.current = finish_label(b, body_label)
	bind_loop_body(b, node.body, post_label, loop_label)
	add_antecedent(b, loop_label, b.current)
	b.current = finish_label(b, post_label)
}

@(private)
bind_do_while :: proc(b: ^Binder, node: ast.Do_While) {
	loop_label := new_loop_label(b)
	condition_label := new_branch_label(b)
	post_label := new_branch_label(b)
	enter_loop(b, loop_label)
	bind_loop_body(b, node.body, post_label, condition_label)
	add_antecedent(b, condition_label, b.current)
	b.current = finish_label(b, condition_label)
	bind_condition(b, node.condition, loop_label, post_label)
	b.current = finish_label(b, post_label)
}

@(private)
bind_for :: proc(b: ^Binder, id: ast.Node_ID, node: ast.For) {
	previous := open_scope(b, .Block, id)
	declare_statement(b, node.init)

	loop_label := new_loop_label(b)
	body_label := new_branch_label(b)
	update_label := new_branch_label(b)
	post_label := new_branch_label(b)
	bind_node(b, node.init)
	enter_loop(b, loop_label)
	// A `for` without a condition never leaves by it: only `break` reaches the code after it.
	bind_condition(b, node.condition, body_label, post_label)
	b.current = finish_label(b, body_label)
	bind_loop_body(b, node.body, post_label, update_label)
	add_antecedent(b, update_label, b.current)
	b.current = finish_label(b, update_label)
	bind_node(b, node.update)
	add_antecedent(b, loop_label, b.current)
	b.current = finish_label(b, post_label)

	close_scope(b, previous)
}

@(private)
bind_for_of :: proc(b: ^Binder, id: ast.Node_ID, node: ast.For_Of) {
	previous := open_scope(b, .Block, id)
	declare_statement(b, node.declaration)

	loop_label := new_loop_label(b)
	post_label := new_branch_label(b)
	// The iterable is read once, before the loop, but inside its scope: `for (const x of x)` reads
	// the loop variable, which check rejects.
	bind_node(b, node.iterable)
	enter_loop(b, loop_label)
	add_antecedent(b, post_label, b.current) // an empty iterable runs the body no times
	bind_node(b, node.declaration)
	add_assignment(b, id) // the loop variable takes the next element
	bind_loop_body(b, node.body, post_label, loop_label)
	add_antecedent(b, loop_label, b.current)
	b.current = finish_label(b, post_label)

	close_scope(b, previous)
}

// bind_loop_body binds the body of a loop with its jump targets in place.
@(private)
bind_loop_body :: proc(b: ^Binder, body: ast.Node_ID, break_label, continue_label: Label_ID) {
	previous_break, previous_continue := b.break_target, b.continue_target
	b.break_target, b.continue_target = break_label, continue_label
	bind_node(b, body)
	b.break_target, b.continue_target = previous_break, previous_continue
}

// bind_switch binds a `switch`: every case is a path from the head, plus the path that falls
// through from the case before it. Cases that hold no statements share the path of the next one,
// so `case 2: case 3: b()` is one range. All the cases share one scope, as a block does.
@(private)
bind_switch :: proc(b: ^Binder, id: ast.Node_ID, node: ast.Switch) {
	post_label := new_branch_label(b)
	bind_node(b, node.value)

	previous := open_scope(b, .Block, id)
	previous_break := b.break_target
	b.break_target = post_label
	for case_id in node.cases {
		clause := b.tree.nodes[case_id].variant.(ast.Case)
		declare_statements(b, clause.statements)
	}

	head := b.current
	fallthrough_flow := UNREACHABLE
	has_default := false
	for index := 0; index < len(node.cases); index += 1 {
		clause_start := index
		for is_empty_case(b, node.cases[index]) && index + 1 < len(node.cases) {
			if fallthrough_flow == UNREACHABLE {
				b.current = head
			}
			has_default ||= is_default_case(b, node.cases[index])
			bind_case(b, node.cases[index])
			index += 1
		}
		has_default ||= is_default_case(b, node.cases[index])

		case_label := new_branch_label(b)
		add_antecedent(b, case_label, switch_clause_flow(b, id, head, clause_start, index + 1))
		add_antecedent(b, case_label, fallthrough_flow)
		b.current = finish_label(b, case_label)
		bind_case(b, node.cases[index])
		fallthrough_flow = b.current
	}
	add_antecedent(b, post_label, b.current)
	if !has_default {
		// The path taken when no case matched: check narrows the value by every case at once.
		add_antecedent(b, post_label, switch_clause_flow(b, id, head, 0, 0))
	}

	b.break_target = previous_break
	close_scope(b, previous)
	b.current = finish_label(b, post_label)
}

@(private)
bind_case :: proc(b: ^Binder, id: ast.Node_ID) {
	clause := b.tree.nodes[id].variant.(ast.Case)
	bind_node(b, clause.value)
	bind_statements(b, clause.statements)
}

@(private)
is_empty_case :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	clause := b.tree.nodes[id].variant.(ast.Case)
	return len(clause.statements) == 0
}

@(private)
is_default_case :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	clause := b.tree.nodes[id].variant.(ast.Case)
	return clause.value == ast.NO_NODE
}

// bind_conditional binds `c ? a : b`. When neither side wrote anything, the flow after it is the
// flow before it: a join that narrows nothing would only make check walk further.
@(private)
bind_conditional :: proc(b: ^Binder, node: ast.Conditional) {
	true_label := new_branch_label(b)
	false_label := new_branch_label(b)
	post_label := new_branch_label(b)
	before := b.current
	had_effects := b.has_flow_effects
	b.has_flow_effects = false

	bind_condition(b, node.condition, true_label, false_label)
	b.current = finish_label(b, true_label)
	bind_node(b, node.then_value)
	add_antecedent(b, post_label, b.current)
	b.current = finish_label(b, false_label)
	bind_node(b, node.else_value)
	add_antecedent(b, post_label, b.current)

	b.current = finish_label(b, post_label) if b.has_flow_effects else before
	b.has_flow_effects ||= had_effects
}
