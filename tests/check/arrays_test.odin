package check_tests

import "core:testing"

@(test)
indexing_a_union_of_strings_gives_a_string :: proc(t: ^testing.T) {
	// Every value of the union is a string, so `s[i]` is one too. The rule asks what the value is
	// based on rather than naming the shapes a string can have.
	c := expect_checked(
		t,
		lines(
			`const choice: "a" | "b" = "a";`, //
			`const letter = choice[0];`,
		),
	)

	testing.expect_value(t, declared_text(c, "letter"), "string")
}

@(test)
an_array_literal_reads_a_context_behind_undefined :: proc(t: ^testing.T) {
	// An optional parameter and a variable written `T | undefined` are unions, and the one member
	// with the shape of an array is the context the literal is going into.
	c := expect_checked(
		t,
		lines(
			`function size(xs?: number[]): number { return xs === undefined ? 0 : xs.length; }`, //
			`const answer = size([]);`,
			`let ys: number[] | undefined = [];`,
			`let zs: (number | string)[] | null = [1];`,
		),
	)

	// A union is ordered by structure, so the declared type reads back in canonical order.
	testing.expect_value(t, declared_text(c, "ys"), "undefined | number[]")
	testing.expect_value(t, declared_text(c, "zs"), "null | (number | string)[]")
}
