package check_tests

import "core:testing"

// `as` and `x!`: the two places where requirements 3.8 lets a program say more than the rules
// worked out, and the two the compiler backs with a runtime check instead of trusting it.

@(test)
a_literal_takes_the_type_it_is_asserted_as :: proc(t: ^testing.T) {
	// The literal is typed with the target as its context, as tsc types it, so its strings stay
	// the literal types K is made of and its object is the named type.
	c := expect_checked(
		t,
		lines(
			`type K = "a" | "b";`, //
			`interface P { k: K; n: number }`,
			`const keys = ["a", "b"] as K[];`,
			`const point = { k: "a", n: 1 } as P;`,
		),
	)
	testing.expect_value(t, declared_text(c, "keys"), "(\"a\" | \"b\")[]")
	testing.expect_value(t, declared_text(c, "point"), "P")
	// A literal that the target does not fit is still unrelated to it, and said so once.
	expect_errors(t, `const bad = [1] as string[];`, []Error{{.Unrelated_Assertion, 1, 13}})
}
