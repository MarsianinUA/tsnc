package check_tests

import "core:testing"

// The two rules that ask whether a path leads from the start of a function to a point: a function
// with a declared result that can end without a `return`, and a `let` read before anything gave it
// a value. Both walk the graph bind built, and both stop at a `return`, at a call that never
// returns and at a `switch` whose cases cover every value.

// A missing `return`.

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
