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
a_bare_return_beside_one_with_a_value_gives_undefined :: proc(t: ^testing.T) {
	// `return;` hands the caller `undefined`, and it is only where every `return` is bare that the
	// body has no value at all and the result is `void`.
	c := expect_checked(t, `function maybe(flag: boolean) { if (flag) { return; } return 1; }`)

	testing.expect_value(t, declared_text(c, "maybe"), "(flag: boolean) => number | undefined")
}

// A name inside its own initializer.

@(test)
an_arrow_with_a_return_type_may_call_itself :: proc(t: ^testing.T) {
	// The signature is known without the body, so it lands on the declaration before the body goes
	// in, exactly as an annotated `function` declaration's does.
	c := expect_checked(
		t,
		lines(
			`const tick = (n: number): void => { if (n > 0) { tick(n - 1); } };`, //
			`const tock: (n: number) => void = n => { if (n > 0) { tock(n - 1); } };`,
		),
	)

	testing.expect_value(t, declared_text(c, "tick"), "(n: number) => void")
	testing.expect_value(t, declared_text(c, "tock"), "(n: number) => void")
}
