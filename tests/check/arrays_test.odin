package check_tests

import "core:testing"

@(test)
an_array_literal_takes_its_element_type_from_its_elements :: proc(t: ^testing.T) {
	// Requirements 5 takes an array's element type from its literal, widened: an element can take
	// another value of its kind later.
	c := expect_checked(t, `const numbers = [1, 2, 3];`)

	testing.expect_value(t, declared_text(c, "numbers"), "number[]")
}

@(test)
elements_of_several_kinds_make_a_union :: proc(t: ^testing.T) {
	c := expect_checked(t, `const mixed = [1, "a"];`)

	testing.expect_value(t, declared_text(c, "mixed"), "(number | string)[]")
}

@(test)
an_array_type_and_the_generic_name_are_one_type :: proc(t: ^testing.T) {
	// `number[]` and `Array<number>` name one type, so they have one layout in T5.7 and one id here.
	c := expect_checked(
		t,
		lines(
			`const written: number[] = [1];`, //
			`const named: Array<number> = written;`,
		),
	)

	testing.expect_value(t, declared_text(c, "named"), "number[]")
}

@(test)
an_empty_array_literal_takes_the_element_type_from_its_context :: proc(t: ^testing.T) {
	c := expect_checked(t, `const empty: string[] = [];`)

	testing.expect_value(t, declared_text(c, "empty"), "string[]")
}

@(test)
an_empty_array_literal_with_no_context_is_reported :: proc(t: ^testing.T) {
	// Guessing here would push the mistake into the first `push`, where nothing explains it.
	expect_errors(t, `const empty = [];`, []Error{{.Empty_Array_Literal, 1, 15}})
}

@(test)
an_element_that_does_not_fit_the_context_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const numbers: number[] = [1, "a"];`, []Error{{.Type_Mismatch, 1, 31}})
}

@(test)
indexing_an_array_gives_its_element :: proc(t: ^testing.T) {
	// Requirements 3.8 makes reading out of range a runtime error, not a `T | undefined`, so the
	// type of `arr[i]` is the element itself.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const first = numbers[0];`,
		),
	)

	testing.expect_value(t, declared_text(c, "first"), "number")
}

@(test)
indexing_a_string_gives_a_string :: proc(t: ^testing.T) {
	// The lib file has no index signatures, so the checker knows this rule itself.
	c := expect_checked(
		t,
		lines(
			`const word = "abc";`, //
			`const letter = word[0];`,
		),
	)

	testing.expect_value(t, declared_text(c, "letter"), "string")
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
indexing_something_that_is_no_array_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const count = 1;`, //
			`const first = count[0];`,
		),
		[]Error{{.Not_Indexable, 2, 15}},
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
an_array_of_objects_types :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`const points: Point[] = [{ x: 1, y: 2 }];`,
			`const first = points[0];`,
			`const x = first.x;`,
		),
	)

	testing.expect_value(t, declared_text(c, "points"), "Point[]")
	testing.expect_value(t, declared_text(c, "x"), "number")
}

@(test)
writing_an_element_is_allowed :: proc(t: ^testing.T) {
	// Requirements 3.8 makes `arr[i] = x` grow the array at its end and fail past it, which is a
	// runtime check and not a type rule, so nothing is reported here.
	expect_checked(
		t,
		lines(
			`const numbers: number[] = [1];`, //
			`numbers[0] = 2;`,
		),
	)
}
