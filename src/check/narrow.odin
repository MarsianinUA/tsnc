package check

import "../ast"
import "../bind"

@(private)
NO_CUT :: max(int)

// Answer is what one walk worked out at a flow node: the type the reference holds there, and
// whether any path arrives there at all. The two used to be one, with `never` standing for both,
// and they are not the same thing: an exhausted union is a type, while code nothing reaches is not
// narrowed at all.
@(private)
Answer :: struct {
	type:    Type_ID,
	reached: bool,
	// The shallowest index into Narrowing.loops of a head whose back edge was cut while this
	// answer was worked out, and NO_CUT where none was. Such an answer holds only until that loop
	// has been evaluated, because the head then contributes what the back edge did not.
	cut:     int,
}

// Narrowing is one buffer for the whole check: the walk reads facts check has already recorded and
// never calls check_expression, so no second walk can be running while this one is, which is the
// argument Trail makes for fits.
@(private)
Narrowing :: struct {
	// The answer already worked out for a flow node of this walk, cleared before the next one. It
	// is read by key alone: Odin's map iteration order changes between runs, and a narrowed type
	// reaches the output. Without it a run of branches would be walked once per path through it.
	answers:    map[bind.Flow_ID]Answer,
	// The loop heads the walk is inside right now. A back edge that reaches one again contributes
	// nothing, which is what makes the walk end.
	loops:      [dynamic]bind.Flow_ID,
	// The nodes whose kept answer carries a cut, in the order they were kept. loop_type drops the
	// ones its own evaluation added.
	partial:    [dynamic]bind.Flow_ID,
	// The cut of the answer being worked out right now. See Answer.
	lowest_cut: int,
}

@(private)
make_narrowing :: proc(allocator := context.allocator) -> Narrowing {
	return {
		answers = make(map[bind.Flow_ID]Answer, allocator),
		loops = make([dynamic]bind.Flow_ID, 0, 8, allocator),
		partial = make([dynamic]bind.Flow_ID, 0, 8, allocator),
		lowest_cut = NO_CUT,
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
// Every file the checker reads has fact tables, its own partition's or a scratch set (see Facts), so
// the walk works the same in a file this call types and in one it only reads to learn the type of an
// imported name. Without that, a result inferred from a narrowed value would come out one type in the
// checker that owns the file and another in a checker that merely reads it.
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
	clear(&c.narrowing.partial)
	c.narrowing.lowest_cut = NO_CUT

	answer := flow_type(c, flow, id, declared)
	// Code nothing reaches is not narrowed: a `never` there would only make the next read of the
	// value report a field that the value does have. A reached `never` is the other thing, a union
	// whose members the tests on the way here have all ruled out, and it is let through.
	return answer.type if answer.reached else declared
}

// The walk.

// flow_type steps over the nodes that say nothing about this reference in a loop rather than by
// recursion: a long run of writes to other names is the one shape that could otherwise grow the
// stack with the size of a function.
//
// An answer is kept for the rest of the walk, or, when a back edge was cut while it was worked out,
// until the loop that cut it has been evaluated. Without that a loop body with a run of N `if`
// statements would be walked once per path through it, which is 2^N.
@(private)
flow_type :: proc(
	c: ^Checker,
	start: bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> Answer {
	if hit, found := cached(c, start); found {
		return hit
	}

	flow := start
	for {
		next, steps_on := steps_over(c, flow, reference)
		if !steps_on {
			break
		}
		flow = next
	}
	// The step-over walked on before anything was worked out, and the node it stopped on may have
	// an answer of its own: the head of a `for...of` is reached both directly and through the
	// assignment that gives the loop variable its element.
	if hit, found := cached(c, flow); found {
		return hit
	}

	outer := c.narrowing.lowest_cut
	c.narrowing.lowest_cut = NO_CUT
	type, reached := settled_type(c, flow, reference, declared)
	mine := c.narrowing.lowest_cut
	c.narrowing.lowest_cut = min(outer, mine)

	answer := Answer {
		type    = type,
		reached = reached,
		cut     = mine,
	}
	remember(c, start, answer)
	if flow != start {
		remember(c, flow, answer)
	}
	return answer
}

// cached hands over the cut of an answer along with it: the answer being worked out is no better
// than the answers it was built from.
@(private)
cached :: proc(c: ^Checker, flow: bind.Flow_ID) -> (hit: Answer, found: bool) {
	hit, found = c.narrowing.answers[flow]
	if found {
		c.narrowing.lowest_cut = min(c.narrowing.lowest_cut, hit.cut)
	}
	return hit, found
}

// remember puts an answer with a cut on the partial list as well, so that the loop it was cut under
// can drop it again.
@(private)
remember :: proc(c: ^Checker, flow: bind.Flow_ID, answer: Answer) {
	c.narrowing.answers[flow] = answer
	if answer.cut != NO_CUT {
		append(&c.narrowing.partial, flow)
	}
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

@(private)
settled_type :: proc(
	c: ^Checker,
	flow: bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> (
	type: Type_ID,
	reached: bool,
) {
	switch node in c.at.bound.flow[flow] {
	case bind.Flow_Unreachable:
		return declared, false
	case bind.Flow_Start:
		return start_type(c, node, reference, declared)
	case bind.Flow_Branch:
		return joined_type(c, node.antecedents, reference, declared)
	case bind.Flow_Loop:
		return loop_type(c, flow, node.antecedents, reference, declared)
	case bind.Flow_Assignment:
		written, _ := written_type(c, node.node, reference)
		return reduce_to_assigned(c, declared, written), true
	case bind.Flow_Condition:
		before := flow_type(c, node.antecedent, reference, declared)
		if !before.reached {
			return before.type, false
		}
		return condition_type(c, node, reference, before.type), true
	case bind.Flow_Switch_Clause:
		before := flow_type(c, node.antecedent, reference, declared)
		if !before.reached {
			return before.type, false
		}
		if node.clause_start == node.clause_end && switch_exhausted(c, node) {
			// Every value the subject can hold matched a case, so the path bind draws for "nothing
			// matched" is no path at all.
			return before.type, false
		}
		return switch_clause_type(c, node, reference, before.type), true
	case bind.Flow_Call:
		// The callee returns `never`, so no path goes on past the call.
		return NEVER, false
	}
	return declared, true
}

// start_type lets a narrowing made outside an arrow hold inside it, because an arrow keeps the flow
// where it was created; a function declaration is hoisted and may run at any point, so bind leaves
// its outer flow unreachable.
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
) -> (
	type: Type_ID,
	reached: bool,
) {
	if node.outer == bind.UNREACHABLE || assigned_anywhere(c, reference) {
		return declared, true
	}
	answer := flow_type(c, node.outer, reference, declared)
	return answer.type, answer.reached
}

@(private)
joined_type :: proc(
	c: ^Checker,
	antecedents: []bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> (
	type: Type_ID,
	reached: bool,
) {
	parts := make([dynamic]Type_ID, 0, len(antecedents), context.temp_allocator)
	for antecedent in antecedents {
		answer := flow_type(c, antecedent, reference, declared)
		if !answer.reached {
			continue
		}
		reached = true
		append(&parts, answer.type)
	}
	if !reached {
		return declared, false
	}
	return union_type(&c.table, parts[:]), true
}

// loop_type is what makes the walk end: a back edge that reaches the head again finds it on the
// stack and contributes nothing.
//
// Every cycle of the graph passes a loop head, and that head is on the stack between an open
// flow_type frame and a second entry into the same node, so an answer worked out under a back edge
// always carries a cut and is dropped here, before the frame outside the loop keeps its own.
@(private)
loop_type :: proc(
	c: ^Checker,
	flow: bind.Flow_ID,
	antecedents: []bind.Flow_ID,
	reference: ast.Node_ID,
	declared: Type_ID,
) -> (
	type: Type_ID,
	reached: bool,
) {
	for head, depth in c.narrowing.loops {
		if head == flow {
			c.narrowing.lowest_cut = min(c.narrowing.lowest_cut, depth)
			return NEVER, false
		}
	}

	mark := len(c.narrowing.partial)
	depth := len(c.narrowing.loops)
	append(&c.narrowing.loops, flow)
	type, reached = joined_type(c, antecedents, reference, declared)
	pop(&c.narrowing.loops)

	for id in c.narrowing.partial[mark:] {
		delete_key(&c.narrowing.answers, id)
	}
	resize(&c.narrowing.partial, mark)
	if c.narrowing.lowest_cut >= depth {
		// Every cut made while this loop was evaluated was cut at this head or at one nested in
		// it, and both have now been settled, so the answer no longer depends on the stack.
		c.narrowing.lowest_cut = NO_CUT
	}
	return type, reached
}

// Writes.

// written_type matches a declarator by symbol, because it writes to the name it declares rather
// than to an expression; the other three write to a place spelled out in the source.
//
// A write to something the reference is read through counts too: `b = other` leaves nothing known
// about `b.v`. The value is then unknown, which is the error type, and reduce_to_assigned turns
// that back into the declared type.
//
// A `for...of` writes an element of the iterable into its loop variable, which for_of_variable
// recorded on the declarator, so the write is read from there.
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
		if declares_root(c, id, reference) {
			return ERROR, true
		}
	case ast.Assign:
		if same_reference(c, v.target, reference) {
			return recorded_type(c, id), true // the assignment holds what the target now has
		}
		if writes_prefix_of(c, v.target, reference) {
			return ERROR, true
		}
	case ast.Update:
		if same_reference(c, v.operand, reference) {
			return NUMBER, true // `++` and `--` always leave a number behind
		}
		if writes_prefix_of(c, v.operand, reference) {
			return ERROR, true
		}
	case ast.For_Of:
		declarator := loop_declarator(c, v.declaration)
		if declares_reference(c, declarator, reference) {
			return recorded_type(c, declarator), true
		}
		if declares_root(c, declarator, reference) {
			return ERROR, true
		}
	}
	return ERROR, false
}

// writes_prefix_of reports whether a write lands on a place the reference is read through: `b` and
// `b.v` are both prefixes of `b.v.w`. The reference itself is not one of them, since its callers
// have already asked about that.
@(private)
writes_prefix_of :: proc(c: ^Checker, target, reference: ast.Node_ID) -> bool {
	for object := object_of(c, reference); object != ast.NO_NODE; object = object_of(c, object) {
		if same_reference(c, target, object) {
			return true
		}
	}
	return false
}

// object_of is the place a reference is read through: `o.a` of `o.a[0]`, and nothing for a name.
@(private)
object_of :: proc(c: ^Checker, id: ast.Node_ID) -> ast.Node_ID {
	unwrapped := unwrap_reference(c, id)
	if unwrapped == ast.NO_NODE {
		return ast.NO_NODE
	}
	#partial switch v in c.at.tree.nodes[unwrapped].variant {
	case ast.Member:
		return v.object
	case ast.Index:
		return v.object
	}
	return ast.NO_NODE
}

// declares_root reports whether a declaring node introduces the name a reference is built on, which
// leaves what was known about a field of it worthless.
@(private)
declares_root :: proc(c: ^Checker, declaration, reference: ast.Node_ID) -> bool {
	root := root_name(c, reference)
	return root != reference && declares_reference(c, declaration, root)
}

// reduce_to_assigned leaves the declared type alone for a value the walk knows nothing about and
// for one that fits no member at all, which is the wider and safer answer.
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

@(private)
loop_declarator :: proc(c: ^Checker, declaration: ast.Node_ID) -> ast.Node_ID {
	node, is_var := c.at.tree.nodes[declaration].variant.(ast.Var_Decl)
	if !is_var || len(node.declarators) != 1 {
		return ast.NO_NODE
	}
	return node.declarators[0]
}

// Conditions.

// condition_type reads a condition bind has already erased `!`, `&&`, `||` and `??` from, so the
// condition node points at what is really tested; `??` is the one that asks about null and
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

// unit_side takes a unit type to be a type with one value: a literal type, `null` or `undefined`,
// which is how requirements 2.2 writes all three kinds of narrowing.
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

// switch_clause_type reads a clause range as the cases that lead to one group of statements, so the
// value is one of theirs; the empty range is the path taken when nothing matched, and rules out
// every case at once.
@(private)
switch_clause_type :: proc(
	c: ^Checker,
	node: bind.Flow_Switch_Clause,
	reference: ast.Node_ID,
	before: Type_ID,
) -> Type_ID {
	statement := c.at.tree.nodes[node.statement].variant.(ast.Switch)
	if node.clause_start == node.clause_end {
		return unmatched_type(c, statement, reference, before)
	}

	count := int(node.clause_end - node.clause_start)
	parts := make([dynamic]Type_ID, 0, count + 1, context.temp_allocator)
	for index in node.clause_start ..< node.clause_end {
		unit, ok := case_unit(c, statement.cases[index])
		if ok {
			append(&parts, narrow_by_place(c, before, statement.value, unit, true, reference))
			continue
		}
		if !is_default(c, statement.cases[index]) {
			// A case value that is not one value picks out no member, so the clause can be entered
			// with anything the subject held.
			return before
		}
		append(&parts, unmatched_type(c, statement, reference, before))
	}
	return union_type(&c.table, parts[:])
}

// unmatched_type is both the path bind draws for "nothing matched" and what a `default` leaves,
// which is what makes `const x: never = s` in a `default` the exhaustiveness check TypeScript users
// write.
@(private)
unmatched_type :: proc(
	c: ^Checker,
	statement: ast.Switch,
	reference: ast.Node_ID,
	before: Type_ID,
) -> Type_ID {
	answer := before
	for id in statement.cases {
		if unit, ok := case_unit(c, id); ok {
			answer = narrow_by_place(c, answer, statement.value, unit, false, reference)
		}
	}
	return answer
}

@(private)
case_unit :: proc(c: ^Checker, id: ast.Node_ID) -> (unit: Type_ID, ok: bool) {
	clause := c.at.tree.nodes[id].variant.(ast.Case)
	if clause.value == ast.NO_NODE {
		return ERROR, false
	}
	unit = unit_type(c, recorded_type(c, clause.value))
	return unit, unit != ERROR
}

@(private)
is_default :: proc(c: ^Checker, id: ast.Node_ID) -> bool {
	return c.at.tree.nodes[id].variant.(ast.Case).value == ast.NO_NODE
}

// Reachability.

// switch_exhausted asks both the subject and the place the subject tests: `switch (s.kind)` rules
// out members of `s` rather than values of `s.kind`, and either one running out means no value is
// left.
//
// A subject check has not typed yet reads the error type and is not exhaustive, which is the wider
// and safer answer.
@(private)
switch_exhausted :: proc(c: ^Checker, node: bind.Flow_Switch_Clause) -> bool {
	statement := c.at.tree.nodes[node.statement].variant.(ast.Switch)
	if nothing_left(c, statement, statement.value) {
		return true
	}
	return nothing_left(c, statement, tested_place(c, statement.value))
}

@(private)
nothing_left :: proc(c: ^Checker, statement: ast.Switch, place: ast.Node_ID) -> bool {
	before := recorded_type(c, place)
	if before == ERROR {
		return false
	}
	return unmatched_type(c, statement, place, before) == NEVER
}

// tested_place is the place a subject reads: `x` of `typeof x`, `s` of `s.kind`. Those are the two
// shapes narrow_by_place answers for besides the place itself.
@(private)
tested_place :: proc(c: ^Checker, id: ast.Node_ID) -> ast.Node_ID {
	if id == ast.NO_NODE {
		return ast.NO_NODE
	}
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Unary:
		if v.op == .Typeof {
			return v.operand
		}
	case ast.Member:
		return v.object
	}
	return ast.NO_NODE
}

// reaches_start reports whether some path leads from the start of a function to flow. A call that
// never returns ends a path, an exhausted `switch` closes the one bind draws for "nothing matched",
// and a write to reference ends one as well when a reference is given.
//
// It is the question behind two rules: a function with a declared result that can end without a
// `return`, and a `let` read before anything gave it a value. The walk is iterative, because a
// function body is as deep as the program is long.
@(private)
reaches_start :: proc(c: ^Checker, flow: bind.Flow_ID, reference := ast.NO_NODE) -> bool {
	if flow == bind.UNREACHABLE {
		return false
	}

	seen := make([]bool, len(c.at.bound.flow), context.temp_allocator)
	work := make([dynamic]bind.Flow_ID, 0, 16, context.temp_allocator)
	seen[flow] = true
	append(&work, flow)

	for len(work) > 0 {
		switch node in c.at.bound.flow[pop(&work)] {
		case bind.Flow_Unreachable:
			continue
		case bind.Flow_Start:
			if reference == ast.NO_NODE || node.outer == bind.UNREACHABLE {
				return true
			}
			// An arrow runs later than the point it was made at, so what matters for a variable it
			// names is whether that variable had a value there.
			walk_back(&work, seen, node.outer)
		case bind.Flow_Branch:
			for antecedent in node.antecedents {
				walk_back(&work, seen, antecedent)
			}
		case bind.Flow_Loop:
			for antecedent in node.antecedents {
				walk_back(&work, seen, antecedent)
			}
		case bind.Flow_Assignment:
			if reference != ast.NO_NODE {
				if _, wrote := written_type(c, node.node, reference); wrote {
					continue // from here on the variable has a value
				}
			}
			walk_back(&work, seen, node.antecedent)
		case bind.Flow_Condition:
			walk_back(&work, seen, node.antecedent)
		case bind.Flow_Switch_Clause:
			if node.clause_start == node.clause_end && switch_exhausted(c, node) {
				continue
			}
			walk_back(&work, seen, node.antecedent)
		case bind.Flow_Call:
			if recorded_type(c, node.call) == NEVER {
				continue // the callee never returns
			}
			walk_back(&work, seen, node.antecedent)
		}
	}
	return false
}

@(private)
walk_back :: proc(work: ^[dynamic]bind.Flow_ID, seen: []bool, flow: bind.Flow_ID) {
	if flow == bind.UNREACHABLE || seen[flow] {
		return
	}
	seen[flow] = true
	append(work, flow)
}

// Filters over the members of a union.

// narrow_by_unit lets a member wider than the value survive `!==`, because it can still hold
// another one: `string | undefined` without `undefined` is `string`, while `string` without `"a"`
// is still `string`.
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

// narrow_by_discriminant is the discriminated union of requirements 2.2: `s.kind === "circle"`
// picks the member whose `kind` is written `"circle"`. A member with no such field is left alone,
// since the test says nothing about it.
//
// The field is worth what a read of it is worth, so `kind?: "a"` is compared as `"a" | undefined`
// and survives `s.kind === undefined`.
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
			type := field_read_type(c, field)
			keep = comparable(c, type, unit) if equals else type != unit
		}
		if keep {
			append(&kept, member)
		}
	}
	return union_type(&c.table, kept[:])
}

// narrow_by_typeof lets a member whose answer is not fixed, such as `any`, survive either way.
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

// typeof_answer is "" where the answer is not fixed. The words are the ones TYPEOF_ANSWERS lists,
// which is what the type of the operator is built from.
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

// union_members answers with a copy, so a loop over it stays safe while its body interns new types
// into the table.
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

// same_reference is the check side of bind's is_narrowable: a name, a field of a place, or an
// element of one at a fixed index.
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

// same_index relies on bind allowing only a literal, a name or a field there; a name picks one
// element only while nothing writes to it.
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

// assigned_anywhere reads bind's Assigned flag, which covers the whole file rather than a point in
// it: the question a closure has to ask.
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

// recorded_type is the error type for a node check has not typed yet. The walk only ever goes
// backwards, so the one way to meet an untyped node is through the back edge of a loop, where the
// write below the use has not been read; an answer that says nothing narrows nothing, which is the
// wider and safer direction.
@(private)
recorded_type :: proc(c: ^Checker, id: ast.Node_ID) -> Type_ID {
	if id == ast.NO_NODE || c.at.node_types == nil {
		return ERROR
	}
	return c.at.node_types[id]
}
