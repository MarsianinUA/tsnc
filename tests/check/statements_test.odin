package check_tests

import "core:testing"

// The control statements of requirements 2.2, and the one of them that has a type of its own: a
// `for...of` takes its variable from what it loops over.

@(test)
a_for_of_takes_its_variable_from_an_array :: proc(t: ^testing.T) {
	// The lib file declares no iterator, so check knows the two things a program may loop over by
	// itself, as check_index knows that `a[i]` is an element.
	c := expect_checked(t, `for (const n of [1, 2, 3]) { console.log(n); }`)
	testing.expect_value(t, use_text(c, "n"), "number")

	c = expect_checked(
		t,
		lines(
			`const names: string[] = ["a"];`, //
			`for (const name of names) { console.log(name); }`,
		),
	)
	testing.expect_value(t, use_text(c, "name"), "string")

	// An array of objects gives the object, and the fields are readable through it.
	c = expect_checked(
		t,
		lines(
			`interface Point { x: number; }`, //
			`const points: Point[] = [{ x: 1 }];`,
			`for (const p of points) { console.log(p.x); }`,
		),
	)
	testing.expect_value(t, use_text(c, "p"), "Point")
	testing.expect_value(t, member_text(c, "x"), "number")
}

@(test)
a_for_of_over_a_string_gives_a_string :: proc(t: ^testing.T) {
	// Requirements 3.2 makes a string a sequence of UTF-16 units, and one unit is a string of one.
	c := expect_checked(
		t,
		lines(
			`const word = "hi";`, //
			`for (const unit of word) { console.log(unit.length); }`,
		),
	)

	testing.expect_value(t, use_text(c, "unit"), "string")
}

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

@(test)
the_control_statements_of_the_subset_type :: proc(t: ^testing.T) {
	// One program with every control statement of requirements 2.2 in it. It is the guard that the
	// walk keeps reaching all of them: a statement check_statement stops naming would type nothing
	// inside it, and no other test would notice.
	expect_checked(
		t,
		lines(
			`function classify(values: number[]): string {`,
			`	let seen = 0;`,
			`	for (let i = 0; i < values.length; i = i + 1) {`,
			`		if (values[i] < 0) {`,
			`			continue;`,
			`		} else {`,
			`			seen = seen + 1;`,
			`		}`,
			`	}`,
			`	while (seen > 10) {`,
			`		seen = seen - 1;`,
			`	}`,
			`	do {`,
			`		seen = seen - 1;`,
			`	} while (seen > 100);`,
			`	for (const value of values) {`,
			`		switch (value) {`,
			`		case 0:`,
			`			break;`,
			`		default:`,
			`			seen = seen + value;`,
			`		}`,
			`	}`,
			`	return seen > 0 ? "some" : "none";`,
			`}`,
			`console.log(classify([1, -2, 3]));`,
		),
	)
}
