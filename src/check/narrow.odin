package check

import "../ast"
import "../bind"

// Narrowing is the state of one walk over the flow graph. One buffer serves the whole check: the
// walk reads facts check has already recorded and never calls check_expression, so no second walk
// can be running while this one is, which is the argument Trail makes for fits.
@(private)
Narrowing :: struct {
	// The answer already worked out for a flow node of this walk, cleared before the next one. It
	// is read by key alone: Odin's map iteration order changes between runs, and a narrowed type
	// reaches the output. Without it a run of branches would be walked once per path through it.
	answers: map[bind.Flow_ID]Type_ID,
	// The loop heads the walk is inside right now. A back edge that reaches one again contributes
	// nothing, which is what makes the walk end.
	loops:   [dynamic]bind.Flow_ID,
}

@(private)
make_narrowing :: proc(allocator := context.allocator) -> Narrowing {
	return {
		answers = make(map[bind.Flow_ID]Type_ID, allocator),
		loops = make([dynamic]bind.Flow_ID, 0, 8, allocator),
	}
}

// narrow_reference is the type a read of one place has where it stands: the declared type, filtered
// by every condition and assignment on the path back to the start of the function. bind recorded
// that path in node_flow for the three shapes a read can take, an ast.Ident, an ast.Member and an
// ast.Index, and the walk follows it backwards.
//
// Only a union is walked for. Requirements 3.4 makes narrowing a tag check over a tagged value, and
// a type with one kind of value is statically typed already; skipping the rest also keeps the cost
// of the walk proportional to the feature rather than to the size of the program.
//
// A file outside this partition has no fact tables, so the walk finds nothing recorded and narrows
// nothing. Today that file is only the lib module, whose declarations have no bodies and therefore
// no flow at all. T3.5 brings in names from other modules, and has to give such a file scratch
// tables, or a function whose result is inferred from a narrowed value would come out one type in
// the checker that owns it and another in a checker that only reads it.
@(private)
narrow_reference :: proc(c: ^Checker, id: ast.Node_ID, declared: Type_ID) -> Type_ID {
	if _, is_union := c.table.types[declared].(Union); !is_union {
		return declared
	}
	flow := c.at.bound.node_flow[id]
	if flow == bind.UNREACHABLE {
		return declared
	}

	clear(&c.narrowing.answers)
	clear(&c.narrowing.loops)
	return flow_type(c, flow, id, declared)
}

// The walk.

// flow_type is the type of the reference at one node of the flow graph. The nodes that say nothing
// about this reference are stepped over in a loop rather than by recursion: a long run of writes to
// other names is the one shape that could otherwise grow the stack with the size of a function.
@(private)
flow_type :: proc(
	c: ^Checker,
	start: bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> Type_ID {
	if answer, found := c.narrowing.answers[start]; found {
		return answer
	}

	flow := start
	for {
		next, steps_on := steps_over(c, flow, reference)
		if !steps_on {
			break
		}
		flow = next
	}

	answer := settled_type(c, flow, reference, declared)
	if len(c.narrowing.loops) == 0 {
		// An answer worked out under a back edge is only part of that loop's answer, so it is not
		// kept: another path would then read a fact that holds one way round the loop and not the
		// next.
		c.narrowing.answers[start] = answer
	}
	return answer
}

// steps_over answers with the node before this one where this one says nothing about the reference:
// a write to another place, and a call that does return. Every other node either ends the walk or
// needs the answer from before it.
@(private)
steps_over :: proc(
	c: ^Checker,
	flow: bind.Flow_ID,
	reference: ast.Node_ID,
) -> (
	before: bind.Flow_ID,
	steps_on: bool,
) {
	#partial switch node in c.at.bound.flow[flow] {
	case bind.Flow_Assignment:
		if _, wrote := written_type(c, node.node, reference); !wrote {
			return node.antecedent, true
		}
	case bind.Flow_Call:
		if recorded_type(c, node.call) != NEVER {
			return node.antecedent, true
		}
	}
	return flow, false
}

// settled_type is the answer of the node the walk stopped on.
@(private)
settled_type :: proc(
	c: ^Checker,
	flow: bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> Type_ID {
	switch node in c.at.bound.flow[flow] {
	case bind.Flow_Unreachable:
		// Code nothing reaches is not narrowed. A `never` here would only make the next read of the
		// value report a field that the value does have.
		return declared
	case bind.Flow_Start:
		return start_type(c, node, reference, declared)
	case bind.Flow_Branch:
		return joined_type(c, node.antecedents, reference, declared)
	case bind.Flow_Loop:
		return loop_type(c, flow, node.antecedents, reference, declared)
	case bind.Flow_Assignment:
		written, _ := written_type(c, node.node, reference)
		return reduce_to_assigned(c, declared, written)
	case bind.Flow_Condition:
		before := flow_type(c, node.antecedent, reference, declared)
		return condition_type(c, node, reference, before)
	case bind.Flow_Switch_Clause:
		before := flow_type(c, node.antecedent, reference, declared)
		return switch_clause_type(c, node, reference, before)
	case bind.Flow_Call:
		return declared // the call never returns, so nothing before it reaches this point
	}
	return declared
}

// start_type is what a reference is worth at the start of a function. An arrow keeps the flow where
// it was created, so a narrowing made outside it still holds inside; a function declaration is
// hoisted and may run at any point, so bind leaves its outer flow unreachable.
//
// The narrowing carries only for a name nothing writes to. A write anywhere in the file could
// happen between the moment the arrow is made and the moment it runs, and bind's Assigned flag
// covers the whole file, which is the question a closure has to ask.
@(private)
start_type :: proc(
	c: ^Checker,
	node: bind.Flow_Start,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> Type_ID {
	if node.outer == bind.UNREACHABLE || assigned_anywhere(c, reference) {
		return declared
	}
	return flow_type(c, node.outer, reference, declared)
}

// joined_type is the type where paths meet: the value is whatever any one of them left.
@(private)
joined_type :: proc(
	c: ^Checker,
	antecedents: []bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> Type_ID {
	parts := make([dynamic]Type_ID, 0, len(antecedents), context.temp_allocator)
	for antecedent in antecedents {
		append(&parts, flow_type(c, antecedent, reference, declared))
	}
	return union_type(&c.table, parts[:])
}

// loop_type is the type at the head of a loop: the path that enters it joined with what comes back
// from the body. A back edge that reaches the head again finds it on the stack and contributes
// nothing, which is what makes the walk end; a head left with nothing at all answers with the
// declared type rather than `never`.
@(private)
loop_type :: proc(
	c: ^Checker,
	flow: bind.Flow_ID,
	antecedents: []bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> Type_ID {
	for head in c.narrowing.loops {
		if head == flow {
			return NEVER
		}
	}

	append(&c.narrowing.loops, flow)
	defer pop(&c.narrowing.loops)
	joined := joined_type(c, antecedents, reference, declared)
	return declared if joined == NEVER else joined
}

// Writes.

// written_type is what one write left in the reference, and whether it wrote there at all. A
// declarator writes to the name it declares rather than to an expression, so it is matched by
// symbol; the other three write to a place spelled out in the source.
//
// A `for...of` gives its loop variable an element of the iterable, whose type is T3.5, so it clears
// what was known and says nothing new.
@(private)
written_type :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	reference: ast.Node_ID,
) -> (
	written: Type_ID,
	wrote: bool,
) {
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Declarator:
		if declares_reference(c, id, reference) {
			return recorded_type(c, v.init), true
		}
	case ast.Assign:
		if same_reference(c, v.target, reference) {
			return recorded_type(c, id), true // the assignment holds what the target now has
		}
	case ast.Update:
		if same_reference(c, v.operand, reference) {
			return NUMBER, true // `++` and `--` always leave a number behind
		}
	case ast.For_Of:
		if declares_reference(c, loop_declarator(c, v.declaration), reference) {
			return ERROR, true
		}
	}
	return ERROR, false
}

// reduce_to_assigned is what a union holds right after a write: the members the written value could
// be. A value the walk knows nothing about, and one that fits no member at all, both leave the
// declared type alone, which is the wider and safer answer.
@(private)
reduce_to_assigned :: proc(c: ^Checker, declared, written: Type_ID) -> Type_ID {
	if written == ERROR || written == ANY {
		return declared
	}

	members := union_members(c, declared)
	kept := make([dynamic]Type_ID, 0, len(members), context.temp_allocator)
	for member in members {
		if fits(c, written, member) {
			append(&kept, member)
		}
	}

	reduced := union_type(&c.table, kept[:])
	return declared if reduced == NEVER else reduced
}

// loop_declarator is the one binding a `for...of` header declares.
@(private)
loop_declarator :: proc(c: ^Checker, declaration: ast.Node_ID) -> ast.Node_ID {
	node, is_var := c.at.tree.nodes[declaration].variant.(ast.Var_Decl)
	if !is_var || len(node.declarators) != 1 {
		return ast.NO_NODE
	}
	return node.declarators[0]
}

// Conditions.

// condition_type applies what one test proved. bind has already erased `!`, `&&`, `||` and `??`, so
// the condition node points at what is really tested; `??` is the one that asks about null and
// undefined rather than about truth.
@(private)
condition_type :: proc(
	c: ^Checker,
	node: bind.Flow_Condition,
	reference: ast.Node_ID,
	before: Type_ID,
) -> Type_ID {
	if node.kind == .Not_Nullish {
		if !same_reference(c, node.condition, reference) {
			return before
		}
		return part_of(&c.table, before, .Not_Nullish if node.assume_true else .Nullish)
	}
	return truthy_type(c, node.condition, node.assume_true, reference, before)
}

// truthy_type applies a test for truth: the reference used as a condition of its own, or a
// comparison of a place with one value.
@(private)
truthy_type :: proc(
	c: ^Checker,
	condition: ast.Node_ID,
	assume_true: bool,
	reference: ast.Node_ID,
	before: Type_ID,
) -> Type_ID {
	if condition == ast.NO_NODE {
		return before
	}
	if same_reference(c, condition, reference) {
		return part_of(&c.table, before, .Truthy if assume_true else .Falsy)
	}

	node, is_binary := c.at.tree.nodes[condition].variant.(ast.Binary)
	if !is_binary {
		return before
	}
	equals: bool
	#partial switch node.op {
	case .Strict_Equal:
		equals = assume_true
	case .Strict_Not_Equal:
		equals = !assume_true
	case:
		// `==` is allowed only where both sides already have one type (requirements 3.7), so it
		// narrows nothing `===` does not, and a use outside that is a mistake check reports.
		return before
	}

	unit, place := unit_side(c, node)
	if unit == ERROR {
		return before
	}
	return narrow_by_place(c, before, place, unit, equals, reference)
}

// unit_side splits a comparison into the value it tests against and the expression that is tested.
// A unit type is a type with one value: a literal type, `null` or `undefined`, which is how
// requirements 2.2 writes all three kinds of narrowing.
@(private)
unit_side :: proc(c: ^Checker, node: ast.Binary) -> (unit: Type_ID, place: ast.Node_ID) {
	if type := unit_type(c, recorded_type(c, node.right)); type != ERROR {
		return type, node.left
	}
	if type := unit_type(c, recorded_type(c, node.left)); type != ERROR {
		return type, node.right
	}
	return ERROR, ast.NO_NODE
}

// unit_type is the type itself where it has one value, and the error type otherwise.
@(private)
unit_type :: proc(c: ^Checker, id: Type_ID) -> Type_ID {
	if id == NULL || id == UNDEFINED {
		return id
	}
	if _, is_literal := c.table.types[id].(Literal); is_literal {
		return id
	}
	return ERROR
}

// narrow_by_place applies `place === unit` to what the reference held. The place is the reference
// itself, `typeof` of it, or a field of it, which are the three kinds of narrowing requirements 2.2
// lists; anything else says nothing about this reference.
@(private)
narrow_by_place :: proc(
	c: ^Checker,
	before: Type_ID,
	place: ast.Node_ID,
	unit: Type_ID,
	equals: bool,
	reference: ast.Node_ID,
) -> Type_ID {
	if place == ast.NO_NODE {
		return before
	}
	if same_reference(c, place, reference) {
		return narrow_by_unit(c, before, unit, equals)
	}

	#partial switch v in c.at.tree.nodes[place].variant {
	case ast.Unary:
		if v.op != .Typeof || !same_reference(c, v.operand, reference) {
			return before
		}
		if answer, is_string := literal_text(c, unit); is_string {
			return narrow_by_typeof(c, before, answer, equals)
		}
	case ast.Member:
		if same_reference(c, v.object, reference) {
			return narrow_by_discriminant(c, before, v.name.text, unit, equals)
		}
	}
	return before
}

// The `switch` statement.

// switch_clause_type applies a `switch` to the reference its value names. A clause range holds the
// cases that lead to one group of statements, so the value is one of theirs; the empty range is the
// path taken when nothing matched, and rules out every case at once.
@(private)
switch_clause_type :: proc(
	c: ^Checker,
	node: bind.Flow_Switch_Clause,
	reference: ast.Node_ID,
	before: Type_ID,
) -> Type_ID {
	statement := c.at.tree.nodes[node.statement].variant.(ast.Switch)
	if node.clause_start == node.clause_end {
		answer := before
		for id in statement.cases {
			if unit, ok := case_unit(c, id); ok {
				answer = narrow_by_place(c, answer, statement.value, unit, false, reference)
			}
		}
		return answer
	}

	count := int(node.clause_end - node.clause_start)
	parts := make([dynamic]Type_ID, 0, count, context.temp_allocator)
	for index in node.clause_start ..< node.clause_end {
		unit, ok := case_unit(c, statement.cases[index])
		if !ok {
			// A `default` matches whatever the other cases left, and a case value that is not one
			// value picks out no member.
			return before
		}
		append(&parts, narrow_by_place(c, before, statement.value, unit, true, reference))
	}
	return union_type(&c.table, parts[:])
}

// case_unit is the one value a case matches, if it has one. A `default` has no value at all.
@(private)
case_unit :: proc(c: ^Checker, id: ast.Node_ID) -> (unit: Type_ID, ok: bool) {
	clause := c.at.tree.nodes[id].variant.(ast.Case)
	if clause.value == ast.NO_NODE {
		return ERROR, false
	}
	unit = unit_type(c, recorded_type(c, clause.value))
	return unit, unit != ERROR
}

// Filters over the members of a union.

// narrow_by_unit keeps the members that can equal one value, or drops the one member that is that
// value. A member wider than the value survives `!==`, because it can still hold another one:
// `string | undefined` without `undefined` is `string`, while `string` without `"a"` is still
// `string`.
@(private)
narrow_by_unit :: proc(c: ^Checker, id: Type_ID, unit: Type_ID, equals: bool) -> Type_ID {
	members := union_members(c, id)
	kept := make([dynamic]Type_ID, 0, len(members), context.temp_allocator)
	for member in members {
		keep := comparable(c, member, unit) if equals else member != unit
		if keep {
			append(&kept, member)
		}
	}
	return union_type(&c.table, kept[:])
}

// narrow_by_discriminant keeps the members whose field could hold one value. It is the
// discriminated union of requirements 2.2: `s.kind === "circle"` picks the member whose `kind` is
// written `"circle"`. A member with no such field is left alone, since the test says nothing about
// it.
@(private)
narrow_by_discriminant :: proc(
	c: ^Checker,
	id: Type_ID,
	name: string,
	unit: Type_ID,
	equals: bool,
) -> Type_ID {
	members := union_members(c, id)
	kept := make([dynamic]Type_ID, 0, len(members), context.temp_allocator)
	for member in members {
		field, found := field_of(c, member, name)
		keep := true
		if found {
			keep = comparable(c, field.type, unit) if equals else field.type != unit
		}
		if keep {
			append(&kept, member)
		}
	}
	return union_type(&c.table, kept[:])
}

// narrow_by_typeof keeps the members whose `typeof` answer is that word. A member whose answer is
// not fixed, such as `any`, survives either way.
@(private)
narrow_by_typeof :: proc(c: ^Checker, id: Type_ID, answer: string, equals: bool) -> Type_ID {
	members := union_members(c, id)
	kept := make([dynamic]Type_ID, 0, len(members), context.temp_allocator)
	for member in members {
		word := typeof_answer(c, member)
		if word == "" || (word == answer) == equals {
			append(&kept, member)
		}
	}
	return union_type(&c.table, kept[:])
}

// typeof_answer is the word `typeof` gives for a type, and "" where the answer is not fixed. The
// words are the ones TYPEOF_ANSWERS lists, which is what the type of the operator is built from.
@(private)
typeof_answer :: proc(c: ^Checker, id: Type_ID) -> string {
	switch v in c.table.types[id] {
	case Basic_Kind:
		#partial switch v {
		case .Boolean:
			return "boolean"
		case .Number:
			return "number"
		case .String:
			return "string"
		case .Null:
			return "object" // the oldest mistake in the language, and one TypeScript narrows by
		case .Undefined, .Void:
			return "undefined"
		}
		return ""
	case Literal:
		return typeof_answer(c, literal_base(v.value))
	case Function, Overload:
		return "function"
	case Object, Array:
		return "object"
	case Union, Type_Var:
		return ""
	}
	return ""
}

// union_members is the members of a union, or the type itself as a list of one. It is a copy, so a
// loop over it stays safe while its body interns new types into the table.
@(private)
union_members :: proc(c: ^Checker, id: Type_ID) -> []Type_ID {
	if type, is_union := c.table.types[id].(Union); is_union {
		out := make([]Type_ID, len(type.members), context.temp_allocator)
		copy(out, type.members)
		return out
	}
	out := make([]Type_ID, 1, context.temp_allocator)
	out[0] = id
	return out
}

@(private)
literal_text :: proc(c: ^Checker, id: Type_ID) -> (text: string, ok: bool) {
	literal, is_literal := c.table.types[id].(Literal)
	if !is_literal {
		return "", false
	}
	return literal.value.(string)
}

// Places.

// same_reference reports whether two expressions name one place. It is the check side of bind's
// is_narrowable: a name, a field of a place, or an element of one at a fixed index.
@(private)
same_reference :: proc(c: ^Checker, a, b: ast.Node_ID) -> bool {
	left_id, right_id := unwrap_reference(c, a), unwrap_reference(c, b)
	if left_id == ast.NO_NODE || right_id == ast.NO_NODE {
		return false
	}
	if left_id == right_id {
		return true
	}

	#partial switch left in c.at.tree.nodes[left_id].variant {
	case ast.Ident:
		right, is_ident := c.at.tree.nodes[right_id].variant.(ast.Ident)
		if !is_ident {
			return false
		}
		ref := resolve_name(c, left_id, left.name, .Value)
		if ref.symbol == bind.NO_SYMBOL {
			return false // a name check cannot place is no place it can narrow
		}
		return ref == resolve_name(c, right_id, right.name, .Value)
	case ast.Member:
		right, is_member := c.at.tree.nodes[right_id].variant.(ast.Member)
		if !is_member || left.name.text != right.name.text {
			return false
		}
		return same_reference(c, left.object, right.object)
	case ast.Index:
		right, is_index := c.at.tree.nodes[right_id].variant.(ast.Index)
		if !is_index || !same_index(c, left.index, right.index) {
			return false
		}
		return same_reference(c, left.object, right.object)
	}
	return false
}

// same_index reports whether two index expressions pick the same element. bind allows a literal, a
// name or a field there; a name picks one element only while nothing writes to it.
@(private)
same_index :: proc(c: ^Checker, a, b: ast.Node_ID) -> bool {
	#partial switch left in c.at.tree.nodes[a].variant {
	case ast.Number_Literal:
		right, is_number := c.at.tree.nodes[b].variant.(ast.Number_Literal)
		return is_number && left.value == right.value
	case ast.String_Literal:
		right, is_string := c.at.tree.nodes[b].variant.(ast.String_Literal)
		return is_string && left.value == right.value
	}
	return same_reference(c, a, b) && !assigned_anywhere(c, a)
}

// unwrap_reference looks through `x!`, which names the same place as `x`.
@(private)
unwrap_reference :: proc(c: ^Checker, id: ast.Node_ID) -> ast.Node_ID {
	if id == ast.NO_NODE {
		return ast.NO_NODE
	}
	if node, is_non_null := c.at.tree.nodes[id].variant.(ast.Non_Null); is_non_null {
		return unwrap_reference(c, node.expr)
	}
	return id
}

// declares_reference reports whether a declaring node introduces the name a reference is a use of.
@(private)
declares_reference :: proc(c: ^Checker, declaration, reference: ast.Node_ID) -> bool {
	if declaration == ast.NO_NODE {
		return false
	}
	use, is_ident := c.at.tree.nodes[reference].variant.(ast.Ident)
	if !is_ident {
		return false
	}
	symbol := c.at.bound.node_symbols[declaration]
	if symbol == bind.NO_SYMBOL {
		return false
	}
	declared := Symbol_Ref {
		file   = c.at.file,
		symbol = symbol,
	}
	return resolve_name(c, reference, use.name, .Value) == declared
}

// assigned_anywhere reports whether anything in the file writes to the name a reference is built
// on. bind's Assigned flag covers the whole file rather than a point in it, which is the question a
// closure has to ask.
@(private)
assigned_anywhere :: proc(c: ^Checker, reference: ast.Node_ID) -> bool {
	root := root_name(c, reference)
	if root == ast.NO_NODE {
		return true
	}
	use := c.at.tree.nodes[root].variant.(ast.Ident)
	ref := resolve_name(c, root, use.name, .Value)
	if ref.symbol == bind.NO_SYMBOL {
		return true
	}
	return .Assigned in c.program.bound[ref.file].symbols[ref.symbol].flags
}

// root_name is the ast.Ident a narrowable reference is built on: `o` of `o.a[0]`.
@(private)
root_name :: proc(c: ^Checker, id: ast.Node_ID) -> ast.Node_ID {
	if id == ast.NO_NODE {
		return ast.NO_NODE
	}
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Ident:
		return id
	case ast.Member:
		return root_name(c, v.object)
	case ast.Index:
		return root_name(c, v.object)
	case ast.Non_Null:
		return root_name(c, v.expr)
	}
	return ast.NO_NODE
}

// recorded_type is the type check already gave a node, and the error type where it has not typed it
// yet. The walk only ever goes backwards, so the one way to meet an untyped node is through the
// back edge of a loop, where the write below the use has not been read; an answer that says nothing
// narrows nothing, which is the wider and safer direction.
@(private)
recorded_type :: proc(c: ^Checker, id: ast.Node_ID) -> Type_ID {
	if id == ast.NO_NODE || c.at.node_types == nil {
		return ERROR
	}
	return c.at.node_types[id]
}
