package check_tests

import "core:testing"

// The two rules that ask whether a path leads from the start of a function to a point: a function
// with a declared result that can end without a `return`, and a `let` read before anything gave it
// a value. Both walk the graph bind built, and both stop at a `return`, at a call that never
// returns and at a `switch` whose cases cover every value.

// A missing `return`.

@(test)
a_function_that_can_end_without_a_return_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function pick(c: boolean): number {`, //
			`if (c) { return 1; }`,
			`}`,
		),
		[]Error{{.Missing_Return, 1, 28}},
	)
}

@(test)
an_arrow_that_can_end_without_a_return_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		`const pick = (c: boolean): number => { if (c) { return 1; } };`,
		[]Error{{.Missing_Return, 1, 28}},
	)
}

@(test)
a_result_that_takes_undefined_may_end_without_a_return :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function nothing(c: boolean): void { if (c) { return; } }`, //
			`function maybe(c: boolean): number | undefined { if (c) { return 1; } }`,
			`function anything(c: boolean): any { if (c) { return 1; } }`,
		),
	)
}

@(test)
a_body_that_ends_in_a_call_that_never_returns_needs_no_return :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function pick(c: boolean): number {`, //
			`if (c) { return 1; }`,
			`process.exit(1);`,
			`}`,
		),
	)
}

@(test)
a_body_that_ends_in_an_endless_loop_needs_no_return :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function pick(c: boolean): number {`, //
			`while (true) { if (c) { return 1; } }`,
			`}`,
		),
	)
}

@(test)
a_body_that_is_an_exhaustive_switch_of_returns_needs_no_return :: proc(t: ^testing.T) {
	// The path bind draws for "no case matched" is the one that would fall off the end, and every
	// value of the union matched a case, so nothing takes it.
	expect_checked(
		t,
		lines(
			`interface Circle { kind: "circle"; r: number; }`, //
			`interface Square { kind: "square"; side: number; }`,
			`function area(s: Circle | Square): number {`,
			`switch (s.kind) {`,
			`case "circle": return s.r;`,
			`case "square": return s.side;`,
			`}`,
			`}`,
		),
	)
}

@(test)
a_switch_that_leaves_a_case_out_still_needs_a_return :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function name(k: "a" | "b" | "c"): number {`, //
			`switch (k) {`,
			`case "a": return 1;`,
			`case "b": return 2;`,
			`}`,
			`}`,
		),
		[]Error{{.Missing_Return, 1, 36}},
	)
}

@(test)
an_inferred_result_of_an_exhaustive_switch_holds_no_undefined :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Circle { kind: "circle"; r: number; }`, //
			`interface Square { kind: "square"; side: number; }`,
			`function area(s: Circle | Square) {`,
			`switch (s.kind) {`,
			`case "circle": return 1;`,
			`case "square": return 2;`,
			`}`,
			`}`,
		),
	)

	testing.expect_value(t, declared_text(c, "area"), "(s: Circle | Square) => number")
}

// A read before a write.

@(test)
a_let_read_before_any_write_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function size(): number {`, //
			`let s: string;`,
			`return s.length;`,
			`}`,
		),
		[]Error{{.Used_Before_Assigned, 3, 8}},
	)
}

@(test)
a_let_written_on_every_path_is_not_reported :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function size(c: boolean): number {`, //
			`let s: string;`,
			`if (c) { s = "a"; } else { s = "bb"; }`,
			`return s.length;`,
			`}`,
		),
	)
}

@(test)
a_let_written_on_one_path_of_two_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function size(c: boolean): number {`, //
			`let s: string;`,
			`if (c) { s = "a"; }`,
			`return s.length;`,
			`}`,
		),
		[]Error{{.Used_Before_Assigned, 4, 8}},
	)
}

@(test)
a_let_written_in_every_case_of_an_exhaustive_switch_is_not_reported :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function name(k: "a" | "b"): string {`, //
			`let s: string;`,
			`switch (k) {`,
			`case "a": s = "first"; break;`,
			`case "b": s = "second"; break;`,
			`}`,
			`return s;`,
			`}`,
		),
	)
}

@(test)
a_let_written_before_a_loop_may_be_read_inside_it :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function total(xs: number[]): number {`, //
			`let t: number;`,
			`t = 0;`,
			`for (const x of xs) { t = t + x; }`,
			`return t;`,
			`}`,
		),
	)
}

@(test)
a_let_whose_type_takes_undefined_is_never_reported :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function size(): number {`, //
			`let s: string | undefined;`,
			`return s === undefined ? 0 : s.length;`,
			`}`,
		),
	)
}

@(test)
a_for_of_variable_is_never_reported :: proc(t: ^testing.T) {
	// Its declarator has no type of its own to write, so there is no declaration that could start
	// out empty; the header writes the element before the body runs.
	expect_checked(
		t,
		lines(
			`function total(xs: number[]): number {`, //
			`let t = 0;`,
			`for (const x of xs) { t = t + x; }`,
			`return t;`,
			`}`,
		),
	)
}

@(test)
a_compound_assignment_reads_the_target_before_it_writes :: proc(t: ^testing.T) {
	// `s += "a"` means `s = s + "a"`, and `n++` means `n = n + 1`, so each one reads a variable
	// that holds nothing yet, and each one is one message.
	expect_errors(
		t,
		lines(
			`function run(): void {`, //
			`let s: string;`,
			`s += "a";`,
			`let n: number;`,
			`n++;`,
			`}`,
		),
		[]Error{{.Used_Before_Assigned, 3, 1}, {.Used_Before_Assigned, 5, 1}},
	)
}

@(test)
a_plain_write_to_a_let_is_no_read :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function run(): string {`, //
			`let s: string;`,
			`s = "a";`,
			`return s;`,
			`}`,
		),
	)
}

@(test)
a_read_inside_a_function_declaration_is_reported :: proc(t: ^testing.T) {
	// The declaration is hoisted and may run before any assignment, so its start reaches nothing
	// outside it. tsc accepts this and leaves the check to Node, which throws; tsnc emits no such
	// check, so the variable would hold garbage.
	expect_errors(
		t,
		lines(
			`let total: number;`, //
			`function add(n: number): void { total = total + n; }`,
			`total = 0;`,
		),
		[]Error{{.Used_Before_Assigned, 2, 41}},
	)
}

@(test)
a_read_inside_an_arrow_made_before_the_write_is_reported :: proc(t: ^testing.T) {
	// The arrow keeps the flow where it was made, and there the variable held nothing yet.
	expect_errors(
		t,
		lines(
			`let timer: number;`, //
			`const step = (): number => timer + 1;`,
			`timer = 0;`,
		),
		[]Error{{.Used_Before_Assigned, 2, 28}},
	)
}

@(test)
a_read_inside_an_arrow_made_after_the_write_is_not_reported :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`let timer: number;`, //
			`timer = 0;`,
			`const step = (): number => timer + 1;`,
		),
	)
}

@(test)
an_exported_let_with_no_initializer_is_reported_at_its_declaration :: proc(t: ^testing.T) {
	// No walk sees across modules, so the one message stands where the variable is declared, and
	// the module that imports it says nothing a second time.
	expect_program_errors(
		t,
		[]string {
			`export let config: number;`, //
			lines(`import { config } from "./m1.ts";`, `const n: number = config;`),
		},
		[]File_Error{{MAIN, .Used_Before_Assigned, 1, 12}},
	)
}
