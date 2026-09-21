package ast

import "core:slice"

// append_children appends in source order and skips absent children (NO_NODE). Names and literal
// values are not nodes, so they are not children.
//
// This is the one place that knows which fields hold children. A phase that walks the tree with its
// own recursion, such as bind with its scopes, handles the kinds it cares about and calls this for
// the rest.
append_children :: proc(out: ^[dynamic]Node_ID, node: Node) {
	switch v in node.variant {
	// Leaves: no child fields.
	case Bad,
	     Type_Param,
	     Specifier,
	     Break,
	     Continue,
	     Empty,
	     Ident,
	     Number_Literal,
	     String_Literal,
	     Bool_Literal,
	     Null_Literal,
	     Keyword_Type,
	     Literal_Type:
	case Module:
		append(out, ..v.statements)

	// Declarations and modules.
	case Var_Decl:
		append(out, ..v.declarators)
	case Declarator:
		append_present(out, v.type, v.init)
	case Function_Decl:
		append(out, ..v.type_params)
		append(out, ..v.params)
		append_present(out, v.return_type, v.body)
	case Param:
		append_present(out, v.type)
	case Interface_Decl:
		append(out, ..v.type_params)
		append_present(out, v.body)
	case Type_Alias_Decl:
		append(out, ..v.type_params)
		append_present(out, v.type)
	case Import_Named:
		append(out, ..v.specifiers)
		append_present(out, v.path)
	case Import_Namespace:
		append_present(out, v.path)
	case Export_Named:
		append(out, ..v.specifiers)
		append_present(out, v.path)

	// Statements.
	case Block:
		append(out, ..v.statements)
	case Expr_Stmt:
		append_present(out, v.expr)
	case If:
		append_present(out, v.condition, v.then_branch, v.else_branch)
	case Switch:
		append_present(out, v.value)
		append(out, ..v.cases)
	case Case:
		append_present(out, v.value)
		append(out, ..v.statements)
	case For:
		append_present(out, v.init, v.condition, v.update, v.body)
	case For_Of:
		append_present(out, v.declaration, v.iterable, v.body)
	case While:
		append_present(out, v.condition, v.body)
	case Do_While:
		append_present(out, v.body, v.condition)
	case Return:
		append_present(out, v.value)

	// Expressions.
	case Template:
		append(out, ..v.expressions)
	case Array_Literal:
		append(out, ..v.elements)
	case Object_Literal:
		append(out, ..v.properties)
	case Property:
		append_present(out, v.value)
	case Arrow:
		append(out, ..v.params)
		append_present(out, v.return_type, v.body)
	case Unary:
		append_present(out, v.operand)
	case Update:
		append_present(out, v.operand)
	case Binary:
		append_present(out, v.left, v.right)
	case Assign:
		append_present(out, v.target, v.value)
	case Conditional:
		append_present(out, v.condition, v.then_value, v.else_value)
	case Call:
		append_present(out, v.callee)
		append(out, ..v.args)
	case Member:
		append_present(out, v.object)
	case Index:
		append_present(out, v.object, v.index)
	case As:
		append_present(out, v.expr, v.type)
	case Non_Null:
		append_present(out, v.expr)

	// Types.
	case Type_Ref:
		append(out, ..v.args)
	case Array_Type:
		append_present(out, v.element)
	case Union_Type:
		append(out, ..v.members)
	case Function_Type:
		append(out, ..v.type_params)
		append(out, ..v.params)
		append_present(out, v.return_type)
	case Object_Type:
		append(out, ..v.members)
	case Property_Signature:
		append_present(out, v.type)
	}
}

// walk visits a subtree in pre-order, children in source order. The caller owns the stack: it
// pushes the root of the subtree, then calls walk until ok is false. Each call pops one node, pushes
// its children and returns the popped ID:
//
//	append(&stack, ast.ROOT)
//	for id in ast.walk(file.nodes, &stack) { ... }
walk :: proc(nodes: []Node, stack: ^[dynamic]Node_ID) -> (id: Node_ID, ok: bool) {
	id = pop_safe(stack) or_return

	// Pushed in reverse, the first child is popped first.
	first_child := len(stack^)
	append_children(stack, nodes[id])
	slice.reverse(stack^[first_child:])
	return id, true
}

// append_present takes only single child fields: a list field never holds NO_NODE.
@(private)
append_present :: proc(out: ^[dynamic]Node_ID, ids: ..Node_ID) {
	for id in ids {
		if id != NO_NODE {
			append(out, id)
		}
	}
}
