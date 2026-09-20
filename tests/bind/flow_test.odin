package bind_tests

import "core:testing"

import "../../src/ast"
import "../../src/bind"

@(test)
a_condition_leads_to_two_paths :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: number | null) {", //
			"\tif (x === null) { return }",
			"\tx;",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "x", 1), `(else "x === null" start)`)
}

@(test)
paths_join_after_a_branch :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(c: boolean, x: number) {", //
			"\tif (c) { x = 1; }",
			"\tx;",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "x", 1), `(join (= "x = 1" (if "c" start)) (else "c" start))`)
}

@(test)
a_body_that_always_returns_ends_unreachable :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function both(c: boolean): number {", //
			"\tif (c) { return 1 } else { return 2 }",
			"}",
			"function one(c: boolean): number {",
			"\tif (c) { return 1 }",
			"\treturn 2;",
			"}",
			"function some(c: boolean): number {",
			"\tif (c) { return 1 }",
			"}",
		),
	)
	testing.expect(t, body_end_flow(b, "both") == bind.UNREACHABLE)
	testing.expect(t, body_end_flow(b, "one") == bind.UNREACHABLE)
	testing.expect(t, body_end_flow(b, "some") != bind.UNREACHABLE)
}

@(test)
code_after_a_return_is_unreachable :: proc(t: ^testing.T) {
	b := expect_bound(t, "function f(x: number) { return x; x; }")
	testing.expect(t, use_flow(b, "x", 1) == bind.UNREACHABLE)
}

@(test)
a_loop_comes_back_to_its_head :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(n: number) {", //
			"\twhile (n > 0) { n = n - 1; }",
			"\tn;",
			"}",
		),
	)
	expect_flow(
		t,
		b,
		use_flow(b, "n", 3),
		`(else "n > 0" (loop start (= "n = n - 1" (if "n > 0" ^))))`,
	)
}

@(test)
a_for_loop_runs_its_update_before_the_next_turn :: proc(t: ^testing.T) {
	b := expect_bound(t, "for (let i = 0; i < 3; i++) { i; }")
	expect_flow(t, b, use_flow(b, "i", 2), `(if "i < 3" (loop (= "i = 0" start) (= "i++" ^)))`)
}

@(test)
a_for_of_loop_may_run_its_body_no_times :: proc(t: ^testing.T) {
	b := expect_bound(t, lines("for (const item of items) item;", "items;"))
	expect_flow(
		t,
		b,
		use_flow(b, "item", 0),
		`(= "for (const item of items) item;" (loop start ^))`,
	)
	expect_flow(
		t,
		b,
		use_flow(b, "items", 1),
		`(loop start (= "for (const item of items) item;" ^))`,
	)
}

@(test)
a_do_while_loop_runs_its_body_first :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(n: number) {", //
			"\tdo { n = n - 1; } while (n > 0);",
			"\tn;",
			"}",
		),
	)
	expect_flow(
		t,
		b,
		use_flow(b, "n", 3),
		`(else "n > 0" (= "n = n - 1" (loop start (if "n > 0" ^))))`,
	)
}

@(test)
a_loop_without_an_exit_leaves_the_code_after_it_unreachable :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function forever(): number {", //
			"\twhile (true) { }",
			"}",
			"function until(c: boolean): number {",
			"\twhile (true) { if (c) { break } }",
			"}",
			"function endless(): number {",
			"\tfor (;;) { }",
			"}",
		),
	)
	testing.expect(t, body_end_flow(b, "forever") == bind.UNREACHABLE)
	testing.expect(t, body_end_flow(b, "until") != bind.UNREACHABLE)
	testing.expect(t, body_end_flow(b, "endless") == bind.UNREACHABLE)
}

@(test)
a_loop_that_nothing_reaches_stays_unreachable :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(c: boolean, n: number): number {", //
			"\treturn 1;",
			"\twhile (c) { n = 2; n; continue; }",
			"\tfor (;;) { n; break; }",
			"}",
		),
	)
	// Dead code has no flow at all, inside a loop as anywhere else: check must always find a
	// Flow_Start by walking back, and never a cycle of back edges alone. check_bound holds the
	// other half: such a loop leaves no node behind. Its jumps still have a loop to go to.
	testing.expect(t, use_node(b, "n", 2) != ast.NO_NODE)
	testing.expect(t, use_flow(b, "n", 1) == bind.UNREACHABLE)
	testing.expect(t, use_flow(b, "n", 2) == bind.UNREACHABLE)
}

@(test)
continue_goes_to_the_head_of_its_loop :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(n: number) {", //
			"\twhile (n > 0) {",
			"\t\tif (n === 1) { continue }",
			"\t\tn = n - 1;",
			"\t}",
			"}",
		),
	)
	// The head is reached from before the loop, from the end of the body and from the continue.
	head := use_flow(b, "n", 0) // the condition reads the loop head
	loop, is_loop := b.bound.flow[head].(bind.Flow_Loop)
	testing.expectf(t, is_loop && len(loop.antecedents) == 3, "the head is %v", b.bound.flow[head])
}

@(test)
every_case_of_a_switch_is_a_path_from_its_head :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(k: \"a\" | \"b\" | \"c\") {", //
			"\tswitch (k) {",
			"\t\tcase \"a\":",
			"\t\tcase \"b\": k; break;",
			"\t\tdefault: k;",
			"\t}",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "k", 1), `(case 0..2 start)`)
	expect_flow(t, b, use_flow(b, "k", 2), `(case 2..3 start)`)
}

@(test)
a_switch_without_a_default_keeps_the_path_where_nothing_matched :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(k: \"a\" | \"b\") {", //
			"\tswitch (k) { case \"a\": return 1; }",
			"\tk;",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "k", 1), `(case 0..0 start)`)
}

@(test)
a_default_clause_may_stand_anywhere :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(k: number, x: number) {", //
			"\tswitch (k) {",
			"\t\tdefault: x; break;",
			"\t\tcase 1: x; break;",
			"\t}",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "x", 0), `(case 0..1 start)`)
	expect_flow(t, b, use_flow(b, "x", 1), `(case 1..2 start)`)
	// A default anywhere means every value lands in a clause: there is no "nothing matched" path.
	testing.expect(t, body_end_flow(b, "f") != bind.UNREACHABLE)
}

@(test)
a_case_falls_through_into_the_next_one :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(k: number, x: number) {", //
			"\tswitch (k) {",
			"\t\tcase 1: x = 1;",
			"\t\tcase 2: x;",
			"\t}",
			"}",
		),
	)
	expect_flow(
		t,
		b,
		use_flow(b, "x", 1),
		`(join (case 1..2 start) (= "x = 1" (case 0..1 start)))`,
	)
}

@(test)
a_case_value_is_read_at_the_head_of_the_switch :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(k: number, x: number, y: number, z: number) {", //
			"\tswitch (k) {",
			"\t\tcase 1: x = 1;",
			"\t\tcase y:",
			"\t\tcase z: x;",
			"\t}",
			"}",
			"function g(w: number) {",
			"\tswitch (w) { case w: }",
			"}",
		),
	)
	// A case is picked before any case runs, so its value sees neither the write that falls through
	// from the case above it nor the narrowing of its own clause, which would be a circle.
	expect_flow(t, b, use_flow(b, "y", 0), "start")
	expect_flow(t, b, use_flow(b, "z", 0), "start")
	expect_flow(t, b, use_flow(b, "w", 1), "start")
	expect_flow(
		t,
		b,
		use_flow(b, "x", 1),
		`(join (case 1..3 start) (= "x = 1" (case 0..1 start)))`,
	)
}

@(test)
logical_operators_test_their_sides_in_turn :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: string | null) {", //
			"\tif (x !== null && x.length > 0) { x; }",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "x", 1), `(if "x !== null" start)`)
	expect_flow(t, b, use_flow(b, "x", 2), `(if "x.length > 0" (if "x !== null" start))`)
}

@(test)
a_negated_condition_swaps_the_two_paths :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: number | null) {", //
			"\tif (!(x === null)) { x; }",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "x", 1), `(else "x === null" start)`)
}

@(test)
a_break_inside_a_switch_leaves_the_switch_and_not_the_loop :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(n: number) {", //
			"\twhile (n > 0) {",
			"\t\tswitch (n) { case 1: break; }",
			"\t\tn = n - 1;",
			"\t}",
			"}",
		),
	)
	// The statement after the switch still runs: the break ended the switch, not the loop.
	testing.expect(t, use_flow(b, "n", 3) != bind.UNREACHABLE)
	expect_flow(
		t,
		b,
		use_flow(b, "n", 2),
		`(join (case 0..1 (if "n > 0" (loop start (= "n = n - 1" ^)))) (case 0..0 (if "n > 0" (loop start (= "n = n - 1" ^)))))`,
	)
}

@(test)
a_jump_with_nowhere_to_go_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, "break;", {{.Break_Outside_Loop, 1, 1}})
	expect_errors(t, "continue;", {{.Continue_Outside_Loop, 1, 1}})
	// A `switch` takes `break` alone, and a loop around it takes the `continue`.
	expect_errors(t, "switch (1) { case 1: continue; }", {{.Continue_Outside_Loop, 1, 22}})
	expect_bound(t, "while (true) { switch (1) { case 1: continue; } }")
	// A loop does not reach into a function written inside it.
	expect_errors(
		t,
		"while (true) { const f = () => { break; }; }",
		{{.Break_Outside_Loop, 1, 34}},
	)

	// The flow goes on past the jump, so one mistake does not turn the rest into dead code.
	b := expect_errors(t, "function f(x: number) { break; x; }", {{.Break_Outside_Loop, 1, 25}})
	expect_flow(t, b, use_flow(b, "x", 0), "start")
}

@(test)
a_return_outside_a_function_is_reported :: proc(t: ^testing.T) {
	// The top level of a module runs on its way in and has nowhere to return to, so tsc rejects
	// this too (TS1108). A function and an arrow are both somewhere to return to.
	expect_errors(t, "return;", {{.Return_Outside_Function, 1, 1}})
	expect_errors(t, "if (true) { return 1; }", {{.Return_Outside_Function, 1, 13}})
	expect_bound(t, "function f(): number { return 1; }")
	expect_bound(t, "const f = (): number => { return 1; };")
	// The value is still bound, so what it reads has a flow and a symbol like any other read.
	b := expect_errors(t, lines("const x = 1;", "return x;"), {{.Return_Outside_Function, 2, 1}})
	expect_flow(t, b, use_flow(b, "x", 0), `(= "x = 1" start)`)
}

@(test)
a_logical_assignment_writes_only_on_one_path :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: number | undefined) {", //
			"\tx ??= 1;",
			"\tx;",
			"}",
		),
	)
	testing.expect(t, symbol_of(b, "x").flags == {.Assigned})
	// The write is on the path where x was nullish; the other path skips it. Both answers of the
	// assignment itself lead on, as they do in tsc, and narrow nothing between them.
	expect_flow(
		t,
		b,
		use_flow(b, "x", 1),
		`(join (defined "x" start) (if "x ??= 1" (= "x ??= 1" (nullish "x" start))) (else "x ??= 1" (= "x ??= 1" (nullish "x" start))))`,
	)
}

@(test)
the_right_side_of_a_coalesce_knows_the_left_one_was_nullish :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: number | undefined, fallback: number) {", //
			"\tconst y = x ?? fallback;",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "fallback", 0), `(nullish "x" start)`)
}

@(test)
a_coalesce_in_a_condition_still_tests_the_value_it_keeps :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(a: number | undefined, b: number) {", //
			"\tif (a ?? b) { a; } else { a; }",
			"}",
		),
	)
	// `0 ?? b` is 0, which takes the else branch: a value that is there is not yet a truthy one.
	expect_flow(
		t,
		b,
		use_flow(b, "a", 1),
		`(join (if "a" (defined "a" start)) (if "b" (nullish "a" start)))`,
	)
	expect_flow(
		t,
		b,
		use_flow(b, "a", 2),
		`(join (else "a" (defined "a" start)) (else "b" (nullish "a" start)))`,
	)
}

@(test)
a_coalesce_under_another_operator_is_tested_even_in_a_value :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(a: number | undefined, b: number, c: number) {", //
			"\tconst y = (a ?? b) && c;",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "b", 0), `(nullish "a" start)`)
	expect_flow(
		t,
		b,
		use_flow(b, "c", 0),
		`(join (if "a" (defined "a" start)) (if "b" (nullish "a" start)))`,
	)
}

@(test)
a_conditional_expression_tests_like_a_branch :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(c: boolean, a: number, other: number) {", //
			"\treturn c ? a : other;",
			"}",
		),
	)
	expect_flow(t, b, use_flow(b, "a", 0), `(if "c" start)`)
	expect_flow(t, b, use_flow(b, "other", 0), `(else "c" start)`)
}

@(test)
a_call_statement_on_a_name_is_a_step_of_its_own :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: number | null) {", //
			"\tif (x === null) { process.exit(1); }",
			"\tx;",
			"}",
		),
	)
	expect_flow(
		t,
		b,
		use_flow(b, "x", 1),
		`(join (call "process.exit(1)" (if "x === null" start)) (else "x === null" start))`,
	)
}

@(test)
an_arrow_keeps_the_flow_where_it_is_created :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(x: string | null) {", //
			"\tif (x !== null) {",
			"\t\tconst read = () => x;",
			"\t}",
			"}",
			"function g() { const plain = () => 1; }",
		),
	)
	expect_flow(t, b, arrow_outer(b, "read"), `(if "x !== null" start)`)
	expect_flow(t, b, arrow_outer(b, "plain"), "start")
}

@(test)
a_field_and_an_element_are_places_check_can_narrow :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function f(o: { a: number }, arr: number[]) {", //
			"\to.a;",
			"\tarr[0];",
			"\to.a = 1;",
			"}",
		),
	)
	member := first_node(b, ast.Member)
	index := first_node(b, ast.Index)
	testing.expect(t, b.bound.node_flow[member] != bind.UNREACHABLE)
	testing.expect(t, b.bound.node_flow[index] != bind.UNREACHABLE)
	// The write to the field is a step of its own, so check can narrow o.a after it.
	expect_flow(t, b, b.bound.node_flow[use_node(b, "o", 1)], "start")
	expect_flow(t, b, body_end_flow(b, "f"), `(= "o.a = 1" start)`)
}

@(private = "file")
expect_flow :: proc(
	t: ^testing.T,
	b: Bound,
	flow: bind.Flow_ID,
	expected: string,
	loc := #caller_location,
) {
	got := flow_dump(b, flow)
	testing.expectf(t, got == expected, "flow\ngot  %s\nwant %s", got, expected, loc = loc)
}

// arrow_outer is the flow where the arrow a name holds is created.
@(private = "file")
arrow_outer :: proc(b: Bound, name: string) -> bind.Flow_ID {
	node := b.bound.scopes[function_scope_of(b, name)].node
	for flow in b.bound.flow {
		start, is_start := flow.(bind.Flow_Start)
		if is_start && start.function == node {
			return start.outer
		}
	}
	return bind.UNREACHABLE
}

@(private = "file")
first_node :: proc(b: Bound, $T: typeid) -> ast.Node_ID {
	for node, id in b.tree.nodes {
		if _, is_kind := node.variant.(T); is_kind {
			return ast.Node_ID(id)
		}
	}
	return ast.NO_NODE
}
