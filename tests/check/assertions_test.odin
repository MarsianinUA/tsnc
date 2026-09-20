package check_tests

import "core:strings"
import "core:testing"

// `as` and `x!`: the two places where requirements 3.8 lets a program say more than the rules
// worked out, and the two the compiler backs with a runtime check instead of trusting it.

// `as`.

@(test)
as_narrows_a_union_and_widens_a_value :: proc(t: ^testing.T) {
	// The two conversions requirements 3.8 allows. Narrowing is the one lower turns into a tag
	// check; widening needs no check at all, since every value of the source is one of the target.
	c := expect_checked(
		t,
		lines(
			`type Both = string | number;`, //
			`function pick(u: Both): string { return u as string; }`,
			`const widened: Both = 1 as Both;`,
		),
	)

	testing.expect_value(t, declared_text(c, "widened"), "number | string")
}

@(test)
as_any_is_rejected :: proc(t: ^testing.T) {
	// Requirements 2.1 puts changing an object's shape through `as any` in the level that is never
	// supported, and 3.8 names the assertion itself.
	c := expect_errors(t, `const bad = 1 as any;`, []Error{{.Unsafe_Assertion, 1, 18}})
	testing.expectf(
		t,
		strings.contains(rendered(c, 0), "`as any`"),
		"the message does not name the assertion: %q",
		rendered(c, 0),
	)
}

@(test)
as_unknown_as_a_type_is_rejected_at_its_first_half :: proc(t: ^testing.T) {
	// Forbidding `unknown` as the target at all is what makes the pair impossible. The first half
	// is already a mistake, and the second one finds the error type and stays quiet, so the program
	// gets one message rather than two.
	expect_errors(t, `const bad = 1 as unknown as string;`, []Error{{.Unsafe_Assertion, 1, 18}})
	expect_errors(t, `const alone = 1 as unknown;`, []Error{{.Unsafe_Assertion, 1, 20}})
}

@(test)
as_between_two_unrelated_types_is_rejected :: proc(t: ^testing.T) {
	c := expect_errors(t, `const bad = "a" as number;`, []Error{{.Unrelated_Assertion, 1, 13}})
	testing.expectf(
		t,
		strings.contains(rendered(c, 0), "cannot be converted"),
		"the message does not say the conversion is impossible: %q",
		rendered(c, 0),
	)
}

// `x!`.

@(test)
non_null_leaves_the_value_that_is_there :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function size(s: string | undefined): number { return s!.length; }`, //
			`function keep(s: string | undefined): string { const v = s!; return v; }`,
		),
	)

	testing.expect_value(t, declared_text(c, "v"), "string")
}

@(test)
non_null_on_a_value_that_is_always_there_is_rejected :: proc(t: ^testing.T) {
	// tsc accepts a `!` that checks nothing. tsnc makes it a runtime check, so one with nothing to
	// check is either a typo or a leftover, and requirements 5 lets the model be the stricter one.
	c := expect_errors(
		t,
		lines(`const n: number = 1;`, `const m = n!;`),
		[]Error{{.Needless_Non_Null, 2, 11}},
	)
	testing.expectf(
		t,
		strings.contains(rendered(c, 0), "nothing to check"),
		"the message does not say the check is empty: %q",
		rendered(c, 0),
	)
}

@(test)
non_null_after_a_narrowing_has_nothing_left_to_check :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function keep(s: string | undefined): string {`, //
			`if (s === undefined) { return "none"; }`,
			`return s!;`,
			`}`,
		),
		[]Error{{.Needless_Non_Null, 3, 8}},
	)
}
