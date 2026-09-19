package bind

import "core:slice"

import "../ast"

// Label_ID indexes the binder's labels, the joins of the flow graph while it is being built.
@(private)
Label_ID :: distinct int

// NO_LABEL is where a `break` outside a loop and a `switch` would go: nowhere.
@(private)
NO_LABEL :: Label_ID(-1)

// Label collects the paths that reach one point. A loop label has its node from the start, since
// the body points back at it; a branch label gets one only when two paths or more arrive.
@(private)
Label :: struct {
	flow:        Flow_ID,
	antecedents: [dynamic]Flow_ID,
}

@(private)
add_flow :: proc(b: ^Binder, node: Flow_Node) -> Flow_ID {
	id := Flow_ID(len(b.flow))
	append(&b.flow, node)
	return id
}

@(private)
new_branch_label :: proc(b: ^Binder) -> Label_ID {
	append(&b.labels, Label{antecedents = make([dynamic]Flow_ID, context.temp_allocator)})
	return Label_ID(len(b.labels) - 1)
}

@(private)
new_loop_label :: proc(b: ^Binder) -> Label_ID {
	flow := add_flow(b, Flow_Loop{})
	append(
		&b.labels,
		Label{flow = flow, antecedents = make([dynamic]Flow_ID, context.temp_allocator)},
	)
	return Label_ID(len(b.labels) - 1)
}

// label_flow is the node of a loop label: the flow of the code at the head of the loop.
@(private)
label_flow :: proc(b: ^Binder, label: Label_ID) -> Flow_ID {
	return b.labels[label].flow
}

// enter_loop records the path into a loop and puts the flow at its head. A loop nothing reaches
// stays unreachable: its head would otherwise be a cycle of back edges alone, with no Flow_Start
// for check to walk back to. tsc enters such a loop anyway and leaves the checker to notice.
@(private)
enter_loop :: proc(b: ^Binder, label: Label_ID) {
	entry := b.current
	add_antecedent(b, label, entry)
	b.current = label_flow(b, label) if entry != UNREACHABLE else UNREACHABLE
}

// add_antecedent records that flow reaches label. A path that cannot be taken adds nothing.
@(private)
add_antecedent :: proc(b: ^Binder, label: Label_ID, flow: Flow_ID) {
	if label == NO_LABEL || flow == UNREACHABLE {
		return
	}
	antecedents := &b.labels[label].antecedents
	if slice.contains(antecedents[:], flow) {
		return
	}
	append(antecedents, flow)
}

// finish_label is the flow after a branch label: nothing reaches it, one path does and stays
// itself, or several join in a node of their own.
@(private)
finish_label :: proc(b: ^Binder, label: Label_ID) -> Flow_ID {
	antecedents := b.labels[label].antecedents
	switch len(antecedents) {
	case 0:
		return UNREACHABLE
	case 1:
		return antecedents[0]
	}
	if b.labels[label].flow == UNREACHABLE {
		b.labels[label].flow = add_flow(b, Flow_Branch{})
	}
	return b.labels[label].flow
}

// bind_jump sends a `break` or a `continue` to its target and ends the flow of its branch.
@(private)
bind_jump :: proc(b: ^Binder, target: Label_ID) {
	if target == NO_LABEL {
		return // outside a loop and a switch; check reports the statement
	}
	add_antecedent(b, target, b.current)
	b.current = UNREACHABLE
}

// add_assignment records a write to a variable, a field or an element.
@(private)
add_assignment :: proc(b: ^Binder, node: ast.Node_ID) {
	b.has_flow_effects = true
	if b.current == UNREACHABLE {
		return
	}
	b.current = add_flow(b, Flow_Assignment{node = node, antecedent = b.current})
}

// bind_call_statement records a call that stands alone as a statement, such as `process.exit(1)`:
// check follows the flow no further when such a call returns `never`.
@(private)
bind_call_statement :: proc(b: ^Binder, expression: ast.Node_ID) {
	if expression == ast.NO_NODE || b.current == UNREACHABLE {
		return
	}
	call, is_call := b.tree.nodes[expression].variant.(ast.Call)
	if !is_call || !is_dotted_name(b, call.callee) {
		return
	}
	b.current = add_flow(b, Flow_Call{call = expression, antecedent = b.current})
	b.has_flow_effects = true
}

// switch_clause_flow is the path from the head of a `switch` to the cases [start, end). An empty
// range is the path where no case matched.
@(private)
switch_clause_flow :: proc(
	b: ^Binder,
	statement: ast.Node_ID,
	head: Flow_ID,
	start, end: int,
) -> Flow_ID {
	if head == UNREACHABLE {
		return UNREACHABLE
	}
	return add_flow(
		b,
		Flow_Switch_Clause {
			statement = statement,
			clause_start = u32(start),
			clause_end = u32(end),
			antecedent = head,
		},
	)
}

// Conditions.

// bind_condition binds an expression that is tested, and records where each answer leads. `!` only
// swaps the two answers, and `&&`, `||` and `??` pass them on to their sides, so the condition
// node lands on what is really tested. kind says what the test means: `??` asks whether its left
// side is null or undefined, everything else asks whether the value is truthy.
@(private)
bind_condition :: proc(
	b: ^Binder,
	id: ast.Node_ID,
	true_label, false_label: Label_ID,
	kind := Condition_Kind.Truthy,
) {
	if id != ast.NO_NODE {
		#partial switch v in b.tree.nodes[id].variant {
		case ast.Unary:
			if v.op == .Not {
				// The kind carries on: `!a ?? b` asks whether `a` is null or undefined, which it
				// answers for a value that `!` has already turned into a boolean, so the path it
				// describes is one the program never takes.
				bind_condition(b, v.operand, false_label, true_label, kind)
				return
			}
		case ast.Binary:
			if _, is_logical := logical_op(v.op); is_logical {
				bind_logical(b, id, true_label, false_label)
				return
			}
		case ast.Assign:
			if _, is_logical := logical_assign_op(v.op); is_logical {
				bind_logical(b, id, true_label, false_label)
				return
			}
		}
		bind_node(b, id)
	}
	add_antecedent(b, true_label, condition_flow(b, id, kind, true))
	add_antecedent(b, false_label, condition_flow(b, id, kind, false))
}

// condition_flow is the path a condition takes when the answer is assume_true. A condition that is
// `true` or `false` in the source takes one path and leaves the other unreachable, which is how
// `while (true)` and a `for` without a condition leave the code after them to `break` alone.
@(private)
condition_flow :: proc(
	b: ^Binder,
	condition: ast.Node_ID,
	kind: Condition_Kind,
	assume_true: bool,
) -> Flow_ID {
	if b.current == UNREACHABLE {
		return UNREACHABLE
	}
	if condition == ast.NO_NODE {
		return b.current if assume_true else UNREACHABLE
	}
	#partial switch v in b.tree.nodes[condition].variant {
	case ast.Bad:
		return b.current // parse reported it; both paths stay open
	case ast.Bool_Literal:
		if kind == .Truthy {
			return b.current if v.value == assume_true else UNREACHABLE
		}
	}
	return add_flow(
		b,
		Flow_Condition {
			condition = condition,
			kind = kind,
			assume_true = assume_true,
			antecedent = b.current,
		},
	)
}

// Logical operators.

// Logical_Op is the operator behind `&&`, `||` and `??`, and behind their assignments.
@(private)
Logical_Op :: enum u8 {
	And,
	Or,
	Coalesce,
}

@(private)
logical_op :: proc(op: ast.Binary_Op) -> (logical: Logical_Op, ok: bool) {
	#partial switch op {
	case .And:
		return .And, true
	case .Or:
		return .Or, true
	case .Coalesce:
		return .Coalesce, true
	}
	return {}, false
}

@(private)
logical_assign_op :: proc(op: ast.Assign_Op) -> (logical: Logical_Op, ok: bool) {
	#partial switch op {
	case .And:
		return .And, true
	case .Or:
		return .Or, true
	case .Coalesce:
		return .Coalesce, true
	}
	return {}, false
}

// bind_logical_value binds a logical expression whose value is used rather than tested: both
// answers join right after it. When neither side wrote anything, the flow stays what it was.
@(private)
bind_logical_value :: proc(b: ^Binder, id: ast.Node_ID) {
	post_label := new_branch_label(b)
	before := b.current
	had_effects := b.has_flow_effects
	b.has_flow_effects = false

	bind_logical(b, id, post_label, post_label)

	b.current = finish_label(b, post_label) if b.has_flow_effects else before
	b.has_flow_effects ||= had_effects
}

// bind_logical binds `a && b`, `a || b`, `a ?? b` or one of their assignments with the two answers
// it leads to.
@(private)
bind_logical :: proc(b: ^Binder, id: ast.Node_ID, true_label, false_label: Label_ID) {
	#partial switch v in b.tree.nodes[id].variant {
	case ast.Binary:
		op, _ := logical_op(v.op)
		bind_logical_left(b, v.left, op, true_label, false_label)
		bind_condition(b, v.right, true_label, false_label)
	case ast.Assign:
		op, _ := logical_assign_op(v.op)
		bind_logical_left(b, v.target, op, true_label, false_label)
		bind_node(b, v.value)
		mark_assigned(b, v.target)
		if is_narrowable(b, v.target) {
			add_assignment(b, id)
		}
		// `a ||= b` is a condition of its own: its value is the left side or the right one.
		add_antecedent(b, true_label, condition_flow(b, id, .Truthy, true))
		add_antecedent(b, false_label, condition_flow(b, id, .Truthy, false))
	case:
		unreachable()
	}
}

// bind_logical_left binds the left side as a condition and leaves the flow where the right side is
// evaluated: after a false answer for `&&`, after a true one for `||`, after a value that is
// neither null nor undefined for `??`.
@(private)
bind_logical_left :: proc(
	b: ^Binder,
	left: ast.Node_ID,
	op: Logical_Op,
	true_label, false_label: Label_ID,
) {
	right_label := new_branch_label(b)
	// The kind reaches the condition node only when the left side is tested as it stands: under a
	// `&&` or a `||` bind_condition passes the answers on to their sides and drops it.
	kind := Condition_Kind.Not_Nullish if op == .Coalesce else Condition_Kind.Truthy
	if op == .And {
		bind_condition(b, left, right_label, false_label, kind)
	} else {
		bind_condition(b, left, true_label, right_label, kind)
	}
	b.current = finish_label(b, right_label)
}

// References.

// is_narrowable reports whether an expression names a place check can narrow: a variable, a field
// of one, or an element at a fixed index.
@(private)
is_narrowable :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	if id == ast.NO_NODE {
		return false
	}
	#partial switch v in b.tree.nodes[id].variant {
	case ast.Ident:
		return true
	case ast.Member:
		return is_narrowable(b, v.object)
	case ast.Non_Null:
		return is_narrowable(b, v.expr)
	case ast.Index:
		return is_fixed_index(b, v.index) && is_narrowable(b, v.object)
	}
	return false
}

@(private)
is_fixed_index :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	#partial switch _ in b.tree.nodes[id].variant {
	case ast.Number_Literal, ast.String_Literal, ast.Ident, ast.Member:
		return true
	}
	return false
}

// is_dotted_name reports whether an expression is a name or a chain of fields, such as
// `process.exit`.
@(private)
is_dotted_name :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	if id == ast.NO_NODE {
		return false
	}
	#partial switch v in b.tree.nodes[id].variant {
	case ast.Ident:
		return true
	case ast.Member:
		return is_dotted_name(b, v.object)
	}
	return false
}
