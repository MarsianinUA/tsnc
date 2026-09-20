package check_tests

import "core:testing"

import "../../src/source"

// Narrowing of a union through the flow graph bind built: requirements 2.2 and 5 list the kinds,
// and requirements 3.4 says what each one comes down to at run time. Every test here also pins what
// the same program says outside the narrowing, because the error is what a user meets first.

// typeof.

@(test)
typeof_picks_the_member_of_the_union :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function size(v: string | number): number {`, //
			`if (typeof v === "string") { return v.length; }`,
			`return v;`,
			`}`,
		),
	)

	// Before the test the value is still both; inside it is a string, and the path that is left
	// after the branch returned is the other one.
	testing.expect_value(t, use_text(c, "v", 0), "number | string")
	testing.expect_value(t, use_text(c, "v", 1), "string")
	testing.expect_value(t, use_text(c, "v", 2), "number")
}

@(test)
a_union_has_no_members_of_its_own_outside_a_narrowing :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function size(v: string | number): number {`, //
			`return v.length;`,
			`}`,
		),
		[]Error{{.Field_Not_Found, 2, 10}},
	)
}

@(test)
typeof_tells_a_function_value_from_a_reference :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function run(v: (() => number) | number): number {`, //
			`if (typeof v === "function") { return v(); }`,
			`return v;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "v", 1), "() => number")
	testing.expect_value(t, use_text(c, "v", 2), "number")
}

// A literal field: discriminated unions.

@(test)
a_literal_field_picks_the_member_it_belongs_to :: proc(t: ^testing.T) {
	c := expect_checked(t, SHAPES)

	testing.expect_value(t, use_text(c, "s", 0), "Circle | Square")
	testing.expect_value(t, use_text(c, "s", 1), "Circle")
	testing.expect_value(t, use_text(c, "s", 2), "Square")
}

@(test)
a_member_of_a_discriminated_union_is_not_readable_before_the_test :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			SHAPE_TYPES, //
			`function area(s: Shape): number {`,
			`return s.r;`,
			`}`,
		),
		[]Error{{.Field_Not_Found, 5, 10}},
	)
}

@(test)
a_switch_narrows_by_the_clause_it_took :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			SHAPE_TYPES, //
			`function area(s: Shape): number {`,
			`switch (s.kind) {`,
			`case "circle": return s.r;`,
			`case "square": return s.side;`,
			`}`,
			`return 0;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "s", 1), "Circle")
	testing.expect_value(t, use_text(c, "s", 2), "Square")
}

@(test)
a_switch_groups_the_cases_that_share_one_body :: proc(t: ^testing.T) {
	// bind gives the cases that lead to one group of statements a single range, so the value is one
	// of theirs; the path where nothing matched rules out every case at once.
	c := expect_checked(
		t,
		lines(
			`function pick(v: "a" | "b" | "c"): string {`, //
			`switch (v) {`,
			`case "a":`,
			`case "b":`,
			`return v;`,
			`}`,
			`return v;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "v", 0), `"a" | "b" | "c"`)
	testing.expect_value(t, use_text(c, "v", 1), `"a" | "b"`)
	testing.expect_value(t, use_text(c, "v", 2), `"c"`)
}

@(test)
a_case_the_value_can_never_equal_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function pick(v: string): number {`, //
			`switch (v) {`,
			`case 1: return 0;`,
			`}`,
			`return 1;`,
			`}`,
		),
		[]Error{{.No_Overlap, 3, 6}},
	)
}

// null and undefined.

@(test)
a_check_against_undefined_leaves_the_value :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function size(s: string | undefined): number {`, //
			`if (s === undefined) { return 0; }`,
			`return s.length;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "s", 0), "string | undefined")
	testing.expect_value(t, use_text(c, "s", 1), "string")
}

@(test)
a_check_against_null_leaves_the_value :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function sum(n: number | null): number {`, //
			`if (n === null) { return 0; }`,
			`return n;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "n", 1), "number")
}

@(test)
an_optional_field_is_read_as_the_type_or_undefined :: proc(t: ^testing.T) {
	// Requirements 3.4: a field written `x?: T` and a `T | undefined` are one representation, so a
	// read of the slot answers with the union and a test against `undefined` takes it apart again.
	c := expect_checked(
		t,
		lines(
			`interface Opts { x?: number; }`, //
			`function get(o: Opts): number {`,
			`if (o.x !== undefined) { return o.x; }`,
			`return 0;`,
			`}`,
		),
	)

	testing.expect_value(t, member_text(c, "x", 0), "number | undefined")
	testing.expect_value(t, member_text(c, "x", 1), "number")
	// The field itself keeps its question mark: only the read of the slot names `undefined`.
	testing.expect_value(t, declared_type_text(c, "Opts"), "Opts")
}

@(test)
an_optional_field_read_without_a_test_does_not_fit_the_type :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Opts { x?: number; }`, //
			`function get(o: Opts): number {`,
			`return o.x;`,
			`}`,
		),
		[]Error{{.Type_Mismatch, 3, 8}},
	)
}

// Truth, and the operators bind erases.

@(test)
a_value_used_as_a_condition_narrows_itself :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function show(name: string | undefined): string {`, //
			`if (name) { return name; }`,
			`return "none";`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "name", 1), "string")
}

@(test)
a_negated_condition_narrows_the_other_way :: proc(t: ^testing.T) {
	// bind swaps the two answers of `!` rather than making a node for it, so check meets the plain
	// test and never the negation.
	c := expect_checked(
		t,
		lines(
			`function show(name: string | undefined): string {`, //
			`if (!name) { return "none"; }`,
			`return name;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "name", 1), "string")
}

@(test)
the_right_side_of_and_knows_what_the_left_one_proved :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function size(s: string | undefined): number {`, //
			`if (s !== undefined && s.length > 0) { return s.length; }`,
			`return 0;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "s", 1), "string")
	testing.expect_value(t, use_text(c, "s", 2), "string")
}

@(test)
the_right_side_of_a_coalesce_knows_the_left_one_was_nullish :: proc(t: ^testing.T) {
	// `??` asks whether the value is null or undefined, not whether it is truthy, so its right side
	// runs exactly where the left one was one of the two.
	expect_checked(
		t,
		lines(
			`function label(x: undefined): string { return "none"; }`, //
			`function show(s: string | undefined): string {`,
			`return s ?? label(s);`,
			`}`,
		),
	)
}

// Assignments.

@(test)
an_assignment_narrows_to_what_it_wrote :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`let v: string | number = 1;`, //
			`const n: number = v;`,
		),
	)

	testing.expect_value(t, use_text(c, "v", 0), "number")
}

@(test)
a_write_inside_a_narrowing_is_measured_against_the_declared_type :: proc(t: ^testing.T) {
	// The reads in the branch are numbers, so `+=` adds; the write itself is measured against what
	// the binding was declared with, or a narrowing would forbid the assignment that ends it.
	c := expect_checked(
		t,
		lines(
			`function f(v: string | number): string {`, //
			`if (typeof v === "number") { v += 1; v = "a"; }`,
			`if (typeof v === "number") { v = "b"; }`,
			`return v;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "v", 5), "string")
}

@(test)
a_write_of_the_wrong_type_is_still_reported_inside_a_narrowing :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function f(v: string | number): void {`, //
			`if (typeof v === "number") { v = true; }`,
			`}`,
		),
		[]Error{{.Type_Mismatch, 2, 34}},
	)
}

// Loops.

@(test)
a_narrowing_holds_inside_the_body_of_a_loop :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function size(s: string | undefined): number {`, //
			`let n: number = 0;`,
			`while (s !== undefined) { n = n + s.length; break; }`,
			`return n;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "s", 1), "string")
}

@(test)
a_write_at_the_end_of_a_loop_reaches_the_top_of_the_next_turn :: proc(t: ^testing.T) {
	// The back edge carries what the body left, so the read at the top of the body sees the write
	// below it. Without that edge this would narrow to the string the declarator wrote.
	expect_errors(
		t,
		lines(
			`let v: string | undefined = "a";`, //
			`let n: number = 0;`,
			`while (n < 3) {`,
			`n = n + v.length;`,
			`v = undefined;`,
			`}`,
		),
		[]Error{{.Field_Not_Found, 4, 11}},
	)
}

// Closures.

@(test)
a_narrowing_carries_into_an_arrow_made_inside_it :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function size(v: string | number): number {`, //
			`if (typeof v === "string") {`,
			`const get = (): number => v.length;`,
			`return get();`,
			`}`,
			`return 0;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "v", 1), "string")
}

@(test)
a_narrowing_does_not_carry_into_an_arrow_when_the_name_is_written_to :: proc(t: ^testing.T) {
	// The write could happen between the moment the arrow is made and the moment it runs, so what
	// held where the arrow was written says nothing inside it.
	expect_errors(
		t,
		lines(
			`let v: string | number = "a";`, //
			`if (typeof v === "string") {`,
			`const get = (): number => v.length;`,
			`v = 1;`,
			`get();`,
			`}`,
		),
		[]Error{{.Field_Not_Found, 3, 29}},
	)
}

// Determinism.

@(test)
a_narrowing_reads_the_same_in_every_partition :: proc(t: ^testing.T) {
	// The walk reads the frozen program and the facts of the file it is in and nothing else, so a
	// file typed on its own and the same file typed beside another give one answer. T6.2 compares
	// the whole output of `-j:1` and `-j:8`, and this is what has to hold for it.
	sources := [2]string {
		`function size(v: string | number): number { return typeof v === "string" ? v.length : v; }`,
		`function other(v: number | boolean): number { return typeof v === "boolean" ? 0 : v; }`,
	}
	together := [2]source.File_ID{MAIN, MAIN + 1}
	alone := [1]source.File_ID{MAIN}

	both := check_sources(t, sources[:], together[:])
	one := check_sources(t, sources[:], alone[:])
	testing.expectf(t, len(both.errors) == 0, "%v", both.errors)

	testing.expect_value(t, use_text(both, "v", 1), "string")
	testing.expect_value(t, use_text(both, "v", 2), "number")
	testing.expect_value(t, use_text(one, "v", 1), use_text(both, "v", 1))
	testing.expect_value(t, use_text(one, "v", 2), use_text(both, "v", 2))
}

// Sources several tests share.

@(private = "file")
SHAPE_TYPES :: `interface Circle { kind: "circle"; r: number; }
interface Square { kind: "square"; side: number; }
type Shape = Circle | Square;`

@(private = "file")
SHAPES ::
	SHAPE_TYPES +
	`
function area(s: Shape): number {
if (s.kind === "circle") { return s.r; }
return s.side;
}`
