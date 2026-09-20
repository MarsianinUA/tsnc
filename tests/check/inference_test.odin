package check_tests

import "core:testing"

@(test)
a_const_keeps_its_literal_type_and_a_let_widens :: proc(t: ^testing.T) {
	// Requirements 5: the type of a variable comes from its initializer, and a `const` keeps the
	// literal type, because the binding never takes another value.
	c := expect_checked(
		t,
		lines(
			`const fixed = 42;`, //
			`let loose = 42;`,
			`const text = "a";`,
			`let words = "a";`,
			`const flag = true;`,
			`let switched = true;`,
		),
	)

	testing.expect_value(t, declared_text(c, "fixed"), "42")
	testing.expect_value(t, declared_text(c, "loose"), "number")
	testing.expect_value(t, declared_text(c, "text"), `"a"`)
	testing.expect_value(t, declared_text(c, "words"), "string")
	testing.expect_value(t, declared_text(c, "flag"), "true")
	testing.expect_value(t, declared_text(c, "switched"), "boolean")
}

@(test)
an_annotation_wins_over_the_initializer :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const kept: number = 42;`, //
			`let given: string | undefined = "a";`,
		),
	)

	testing.expect_value(t, declared_text(c, "kept"), "number")
	testing.expect_value(t, declared_text(c, "given"), "string | undefined")
}

@(test)
a_value_that_does_not_fit_its_annotation_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const count: number = "a";`, []Error{{.Type_Mismatch, 1, 23}})
}

@(test)
a_return_type_is_inferred_from_the_body :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function one() { return 1; }`, //
			`function two(flag: boolean) { if (flag) { return 1; } return "a"; }`,
			`function nothing() { let counter = 1; }`,
			`function bare() { return; }`,
		),
	)

	// What a call hands back is not the one literal the body happened to write, so it widens.
	testing.expect_value(t, declared_text(c, "one"), "() => number")
	testing.expect_value(t, declared_text(c, "two"), "(flag: boolean) => number | string")
	testing.expect_value(t, declared_text(c, "nothing"), "() => void")
	// A bare `return` gives nothing to the union, as in tsc, so a body that returns no value is
	// `void` and not `undefined`.
	testing.expect_value(t, declared_text(c, "bare"), "() => void")
}

@(test)
a_body_that_can_run_off_its_end_also_gives_undefined :: proc(t: ^testing.T) {
	// bind already knows which bodies those are: it leaves the flow after a `return` unreachable.
	c := expect_checked(
		t,
		lines(
			`function maybe(flag: boolean) { if (flag) { return 1; } }`, //
			`function always(flag: boolean) { if (flag) { return 1; } return 2; }`,
		),
	)

	testing.expect_value(t, declared_text(c, "maybe"), "(flag: boolean) => number | undefined")
	testing.expect_value(t, declared_text(c, "always"), "(flag: boolean) => number")
}

@(test)
an_arrow_is_a_value_with_a_signature :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const double = (n: number) => n * 2;`, //
			`const greet = (name: string): string => name;`,
			`const idle = () => {};`,
		),
	)

	testing.expect_value(t, declared_text(c, "double"), "(n: number) => number")
	testing.expect_value(t, declared_text(c, "greet"), "(name: string) => string")
	testing.expect_value(t, declared_text(c, "idle"), "() => void")
}

@(test)
a_return_is_checked_against_the_declared_result :: proc(t: ^testing.T) {
	expect_errors(t, `function count(): number { return "a"; }`, []Error{{.Type_Mismatch, 1, 35}})
}

@(test)
a_recursive_return_type_needs_an_annotation :: proc(t: ^testing.T) {
	// The body would have to know what the function gives back in order to say what it gives back.
	expect_errors(
		t,
		`function endless() { return endless(); }`,
		[]Error{{.Recursive_Return_Type, 1, 10}},
	)
}

@(test)
an_annotated_recursive_function_is_fine :: proc(t: ^testing.T) {
	// The annotation answers before the body is read, so the call inside it finds the answer.
	expect_checked(
		t,
		`function countdown(n: number): number { return n > 0 ? countdown(n - 1) : 0; }`,
	)
}

@(test)
mutually_recursive_functions_need_an_annotation :: proc(t: ^testing.T) {
	// The ring is reported once, where it closes, and not once per function in it.
	expect_errors(
		t,
		lines(
			`function first() { return second(); }`, //
			`function second() { return first(); }`,
		),
		[]Error{{.Recursive_Return_Type, 1, 10}},
	)
}
