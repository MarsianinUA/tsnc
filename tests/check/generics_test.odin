package check_tests

import "core:testing"

// Instantiation of the generic built-in signatures, which requirements 2.2 gives v1 and
// requirements 5 asks to work out from the function a call passes.

@(test)
map_infers_its_result_from_the_arrow :: proc(t: ^testing.T) {
	// The task's third done criterion: `U` of `map<U>` comes from the body of the arrow, and the
	// arrow's parameter comes from the signature, so neither is written down.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const doubled = numbers.map(x => x * 2);`,
		),
	)

	testing.expect_value(t, declared_text(c, "doubled"), "number[]")
	testing.expect_value(t, use_text(c, "x"), "number")
}

@(test)
map_can_change_the_element_type :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const texts = numbers.map(x => x.toFixed(2));`,
		),
	)

	testing.expect_value(t, declared_text(c, "texts"), "string[]")
}

@(test)
map_over_objects_reads_a_field :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`const points: Point[] = [{ x: 1, y: 2 }];`,
			`const xs = points.map(p => p.x);`,
		),
	)

	testing.expect_value(t, declared_text(c, "xs"), "number[]")
}

@(test)
a_call_records_the_signature_it_settled_on :: proc(t: ^testing.T) {
	// The contract of Check_Result names the chosen call signature, so that lower reads the answer
	// instead of working the instantiation out again.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const doubled = numbers.map(x => x * 2);`,
		),
	)

	signature := "(callbackfn: (value: number, index: number, array: number[]) => number) => number[]"
	testing.expect_value(t, call_text(c), signature)
}

@(test)
filter_and_for_each_keep_the_element_type :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const big = numbers.filter(n => n > 1);`,
			`numbers.forEach(n => console.log(n));`,
		),
	)

	testing.expect_value(t, declared_text(c, "big"), "number[]")
}

@(test)
reduce_takes_the_signature_whose_arity_fits :: proc(t: ^testing.T) {
	// The lib file declares `reduce` twice, once with an initial value and once without, and says
	// check picks the first that fits the call.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const total = numbers.reduce((a, b) => a + b);`,
			`const joined = numbers.reduce((text, n) => text + n.toString(), "");`,
		),
	)

	testing.expect_value(t, declared_text(c, "total"), "number")
	testing.expect_value(t, declared_text(c, "joined"), "string")
}

@(test)
an_initial_value_widens_before_it_settles_a_type_variable :: proc(t: ^testing.T) {
	// `0` has the literal type `0`. If `U` took that, the callback could return nothing but zero,
	// so inference widens first, as tsc does.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const total = numbers.reduce((a, b) => a + b, 0);`,
		),
	)

	testing.expect_value(t, declared_text(c, "total"), "number")
}

@(test)
the_array_members_of_the_subset_all_type :: proc(t: ^testing.T) {
	// The array list of requirements 2.2, reached through `Array<T>` instantiated with `number`.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const size = numbers.length;`,
			`const grown = numbers.push(4);`,
			`const last = numbers.pop();`,
			`const at = numbers.indexOf(2);`,
			`const has = numbers.includes(2);`,
			`const part = numbers.slice(1);`,
			`const text = numbers.join(",");`,
		),
	)

	testing.expect_value(t, declared_text(c, "size"), "number")
	testing.expect_value(t, declared_text(c, "grown"), "number")
	testing.expect_value(t, declared_text(c, "last"), "number | undefined")
	testing.expect_value(t, declared_text(c, "at"), "number")
	testing.expect_value(t, declared_text(c, "has"), "boolean")
	testing.expect_value(t, declared_text(c, "part"), "number[]")
	testing.expect_value(t, declared_text(c, "text"), "string")
}

@(test)
two_element_types_instantiate_two_signatures :: proc(t: ^testing.T) {
	// One tree of `Array<T>` stands behind both, so an instantiation must not leave its answers on
	// the lib file's nodes, where the other one would read them.
	c := expect_checked(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const words = ["a", "b"];`,
			`const first = numbers.pop();`,
			`const second = words.pop();`,
		),
	)

	testing.expect_value(t, declared_text(c, "first"), "number | undefined")
	testing.expect_value(t, declared_text(c, "second"), "string | undefined")
}

@(test)
an_arrow_parameter_that_does_not_fit_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const texts = numbers.map((x: string) => x);`,
		),
		[]Error{{.Type_Mismatch, 2, 27}},
	)
}

@(test)
an_arrow_outside_a_call_still_needs_its_annotations :: proc(t: ^testing.T) {
	// Only the signature an arrow goes into can give its parameters a type, and here there is none.
	expect_errors(t, `const twice = x => x * 2;`, []Error{{.Missing_Annotation, 1, 15}})
}

@(test)
a_body_that_does_not_fit_the_signature_is_reported :: proc(t: ^testing.T) {
	// `filter` takes a predicate that returns a boolean, which is narrower than tsc's signature, as
	// the lib file says.
	expect_errors(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const big = numbers.filter(n => n + 1);`,
		),
		[]Error{{.Type_Mismatch, 2, 28}},
	)
}

@(test)
the_wrong_number_of_arguments_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const numbers = [1, 2, 3];`, //
			`const part = numbers.slice(1, 2, 3);`,
		),
		[]Error{{.Argument_Count, 2, 14}},
	)
}
