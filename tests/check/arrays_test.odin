package check_tests

import "core:testing"

@(test)
an_element_that_does_not_fit_the_context_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const numbers: number[] = [1, "a"];`, []Error{{.Type_Mismatch, 1, 31}})
}

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
indexing_with_something_other_than_a_number_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const first = numbers["0"];`,
		),
		[]Error{{.Type_Mismatch, 2, 23}},
	)
}

@(test)
arrays_of_different_elements_do_not_fit_each_other :: proc(t: ^testing.T) {
	// Requirements 3.6 stores elements unboxed, so a `number[]` buffer holds f64 and a
	// `(number | string)[]` buffer holds tagged values. tsc allows this; tsnc cannot.
	expect_errors(
		t,
		lines(
			`const numbers: number[] = [1, 2];`, //
			`const mixed: (number | string)[] = numbers;`,
		),
		[]Error{{.Type_Mismatch, 2, 36}},
	)
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

@(test)
two_array_members_leave_an_empty_literal_without_a_context :: proc(t: ^testing.T) {
	// Nothing here can choose between them, so the literal is as unguessable as it was with no
	// context at all.
	expect_errors(t, `let xs: number[] | string[] = [];`, []Error{{.Empty_Array_Literal, 1, 31}})
}
