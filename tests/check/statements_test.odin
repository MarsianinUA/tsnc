package check_tests

import "core:testing"

// `for...of`, the control statement of requirements 2.2 that has a type of its own: it takes its
// variable from what it loops over.

@(test)
a_for_of_variable_of_a_union_element_narrows :: proc(t: ^testing.T) {
	// The variable is a place like any other, so the flow graph reaches it and a `typeof` inside the
	// body tells the two members apart.
	c := expect_checked(
		t,
		lines(
			`const mixed: (number | string)[] = [1, "a"];`, //
			`for (const item of mixed) {`,
			`	if (typeof item === "string") {`,
			`		console.log(item.length);`,
			`	}`,
			`}`,
		),
	)

	// The declarator holds the name rather than a read of it, so the first read is the one the
	// `typeof` tests and the second is the one inside the branch it proved.
	testing.expect_value(t, use_text(c, "item"), "number | string")
	testing.expect_value(t, use_text(c, "item", 1), "string")
}

@(test)
looping_over_something_that_is_no_sequence_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `for (const n of 42) { console.log(n); }`, []Error{{.Not_Iterable, 1, 17}})
	expect_errors(
		t,
		lines(
			`const p = { x: 1 };`, //
			`for (const n of p) { console.log(n); }`,
		),
		[]Error{{.Not_Iterable, 2, 17}},
	)
	// A union is refused rather than taken apart: requirements 3.4 keeps it as a tagged value, so
	// every turn of the loop would need a tag test. Narrowing it first says the same thing, and a
	// parameter is the shape where nothing has narrowed it yet.
	expect_errors(
		t,
		lines(
			`function count(either: number[] | string[]): void {`, //
			`	for (const n of either) { console.log(n); }`,
			`}`,
		),
		[]Error{{.Not_Iterable, 2, 18}},
	)
}

@(test)
a_for_of_variable_cannot_be_written_to :: proc(t: ^testing.T) {
	// `for (const n of ...)` declares a `const` on every turn, so the body may read it and not
	// change it. parse rejects a header without a declaration, so there is no other shape.
	expect_errors(t, `for (const n of [1, 2]) { n = 3; }`, []Error{{.Assign_To_Const, 1, 27}})
}
