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
