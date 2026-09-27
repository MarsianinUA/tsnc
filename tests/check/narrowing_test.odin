package check_tests

import "core:strings"
import "core:testing"

import "../../src/source"

// Narrowing of a union through the flow graph bind built: requirements 2.2 and 5 list the kinds,
// and requirements 3.4 says what each one comes down to at run time. Every test here also pins what
// the same program says outside the narrowing, because the error is what a user meets first.

// typeof.

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

// Truth, and the operators bind erases.

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
a_write_to_another_name_keeps_what_was_known_about_a_field :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Box { v: number | undefined; }`, //
			`function f(b: Box, k: number): void {`,
			`if (b.v !== undefined) {`,
			`k = 1;`,
			`const n: number = b.v;`,
			`}`,
			`}`,
		),
	)

	testing.expect_value(t, member_text(c, "v", 1), "number")
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
a_loop_body_with_many_branches_is_walked_once :: proc(t: ^testing.T) {
	// An answer worked out under a back edge is kept until the loop that cut it has been
	// evaluated, so a run of N branches in a body costs N walks and not one per path, which is
	// 2^N. Without that this program does not finish.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "function count(k: number, v: string | number): number {\n")
	strings.write_string(&b, "let t = 0;\n")
	strings.write_string(&b, "let x: string | number = v;\n")
	strings.write_string(&b, "while (t < 10) {\n")
	for i in 0 ..< 40 {
		strings.write_string(&b, "if (k === ")
		strings.write_int(&b, i)
		strings.write_string(&b, ") { t = t + ")
		strings.write_int(&b, i)
		strings.write_string(&b, "; }\n")
	}
	strings.write_string(&b, `if (typeof x === "string") { t = t + 1; }`)
	strings.write_string(&b, "\n}\nreturn t;\n}")

	c := expect_checked(t, strings.to_string(b))
	testing.expect_value(t, use_text(c, "x", 0), "number | string")
}

// Calls that never return.

@(test)
a_call_that_never_returns_ends_the_path_it_stands_on :: proc(t: ^testing.T) {
	// `process.exit` answers `never`, so the branch that called it reaches nothing below the `if`,
	// and the join after it holds only the other one.
	c := expect_checked(
		t,
		lines(
			`function size(x: string | undefined): number {`, //
			`if (x === undefined) { process.exit(1); }`,
			`return x.length;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "x", 1), "string")
}

// `switch` and `default`.

@(test)
a_default_clause_narrows_to_what_the_cases_left :: proc(t: ^testing.T) {
	// The exhaustiveness idiom: every value of the union matched a case, so `default` is entered
	// with nothing left, and `never` is what a value that cannot occur is worth.
	expect_checked(
		t,
		lines(
			`type Kind = "a" | "b" | "c";`, //
			`function name(k: Kind): number {`,
			`switch (k) {`,
			`case "a": return 1;`,
			`case "b": return 2;`,
			`case "c": return 3;`,
			`default: {`,
			`const unreachable: never = k;`,
			`return unreachable;`,
			`}`,
			`}`,
			`}`,
		),
	)
}

@(test)
a_default_clause_of_a_switch_that_leaves_a_member_keeps_it :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function name(k: "a" | "b" | "c"): string {`, //
			`switch (k) {`,
			`case "a": return "first";`,
			`default: return k;`,
			`}`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "k", 1), `"b" | "c"`)
}

// An optional discriminant.

@(test)
an_optional_discriminant_survives_a_test_against_undefined :: proc(t: ^testing.T) {
	// `kind?: "a"` reads as `"a" | undefined`, so a value of that member can be the one the test
	// found; narrowing the union to `never` would make the branch below unreachable.
	c := expect_checked(
		t,
		lines(
			`interface Loose { kind?: "a"; left: number; }`, //
			`interface Tight { kind: "b"; right: number; }`,
			`function pick(s: Loose | Tight): number {`,
			`if (s.kind === undefined) { return s.left; }`,
			`return 0;`,
			`}`,
		),
	)

	testing.expect_value(t, use_text(c, "s", 1), "Loose")
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

// `any` and `unknown`.

@(test)
typeof_narrows_any_and_unknown_to_a_primitive :: proc(t: ^testing.T) {
	// As tsc has them: a primitive's word names one type, while "object" and "function" leave
	// `any` as it was.
	c := expect_checked(
		t,
		lines(
			`function f(a: any, u: unknown): number {`, //
			`if (typeof a === "number" && typeof u === "string") { return a + u.length; }`,
			`if (typeof a === "object") { return a === null ? 0 : 2; }`,
			`if (typeof u === "undefined") { return u === undefined ? 3 : 4; }`,
			`return 1;`,
			`}`,
		),
	)
	testing.expect_value(t, use_text(c, "a", 0), "any")
	testing.expect_value(t, use_text(c, "a", 1), "number")
	testing.expect_value(t, use_text(c, "u", 1), "string")
	testing.expect_value(t, use_text(c, "a", 3), "any")
	testing.expect_value(t, use_text(c, "u", 3), "undefined")
}

// Fields of a union.

@(test)
a_write_to_a_field_of_a_union_fits_every_member :: proc(t: ^testing.T) {
	// The object may be any one of the members, so the value has to fit the field of each, and
	// here each holds a number. The refused half is a line of tests/negative/type-mismatch.ts.
	expect_checked(
		t,
		lines(
			`interface A { x: number; }`, //
			`interface B { x: number; y: string; }`,
			`function set(u: A | B): void {`,
			`u.x = 1;`,
			`u.x += 2;`,
			`}`,
		),
	)
}
