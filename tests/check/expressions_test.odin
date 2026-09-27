package check_tests

import "core:testing"

@(test)
double_equals_between_one_type_is_allowed :: proc(t: ^testing.T) {
	c := expect_checked(t, `const same = 1 == 2;`)
	testing.expect_value(t, declared_text(c, "same"), "boolean")
	// One kind of value, with null or undefined beside it, is still `===`.
	expect_checked(
		t,
		lines(
			`function f(a: string | undefined, b: string | undefined): boolean {`, //
			`return a == b;`,
			`}`,
		),
	)
}

@(test)
the_falsy_side_of_or_is_dropped :: proc(t: ^testing.T) {
	// `name || "none"` is a `string`, not `string | undefined`: the left side survives only where
	// it is truthy. tsc types it the same way, and the differential gate of T4.7 runs tsc --strict.
	c := expect_checked(
		t,
		lines(
			`let name: string | undefined = undefined;`, //
			`const shown: string = name || "none";`,
		),
	)

	testing.expect_value(t, declared_text(c, "shown"), "string")
}

@(test)
and_keeps_the_falsy_side_and_coalesce_keeps_the_rest :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const guard = 0 && "x";`, //
			`let maybe: number | null = null;`,
			`const value: number = maybe ?? 0;`,
		),
	)

	// `a && b` is `a` exactly where `a` is falsy.
	testing.expect_value(t, declared_text(c, "guard"), `0 | "x"`)
	// `??` asks only about null and undefined, so the number survives.
	testing.expect_value(t, declared_text(c, "value"), "number")
}

@(test)
not_takes_anything_and_gives_a_boolean :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const empty = !"a";`, //
			`const negated = -1;`,
		),
	)

	testing.expect_value(t, declared_text(c, "empty"), "boolean")
	// A minus in front of a number is part of the number, as tsc reads it.
	testing.expect_value(t, declared_text(c, "negated"), "-1")
}

@(test)
typeof_gives_the_answers_it_can_produce :: proc(t: ^testing.T) {
	c := expect_checked(t, `const kind = typeof 1;`)
	testing.expect_value(
		t,
		declared_text(c, "kind"),
		`"boolean" | "function" | "number" | "object" | "string" | "undefined"`,
	)
}

@(test)
strict_equality_accepts_two_unions_that_share_a_member :: proc(t: ^testing.T) {
	// Neither union fits the other, and `"b"` is still a value both sides can hold, so the
	// comparison is a test and not a mistake.
	expect_checked(
		t,
		lines(
			`function same(a: "a" | "b", b: "b" | "c"): boolean { return a === b; }`, //
			`function wide(a: number | string, b: string | boolean): boolean { return a === b; }`,
		),
	)
}
