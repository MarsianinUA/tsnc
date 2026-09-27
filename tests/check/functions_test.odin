package check_tests

import "core:testing"

@(test)
a_call_checks_the_type_of_each_argument :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function twice(n: number): number { return n * 2; }`, //
			`const answer = twice("a");`,
		),
		[]Error{{.Type_Mismatch, 2, 22}},
	)
}

@(test)
a_call_checks_how_many_arguments_it_passes :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function pair(a: number, b: number): number { return a + b; }`, //
			`const answer = pair(1);`,
		),
		[]Error{{.Argument_Count, 2, 16}},
	)

	expect_errors(
		t,
		lines(
			`function one(a: number): number { return a; }`, //
			`const answer = one(1, 2);`,
		),
		[]Error{{.Argument_Count, 2, 16}},
	)
}

@(test)
a_rest_parameter_takes_any_number_of_arguments :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function total(first: number, ...rest: number[]): number { return first; }`, //
			`const none = total(1);`,
			`const some = total(1, 2, 3);`,
		),
	)
}

@(test)
a_function_that_asks_for_more_does_not_fit :: proc(t: ^testing.T) {
	expect_errors(
		t,
		`const greedy: (a: number) => void = (a: number, b: number) => {};`,
		[]Error{{.Type_Mismatch, 1, 37}},
	)
}

@(test)
a_function_result_that_does_not_fit_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		`const wrong: (a: number) => number = (a: number): string => "x";`,
		[]Error{{.Type_Mismatch, 1, 38}},
	)
}

// Rest and optional parameters.

@(test)
a_positional_array_does_not_fit_a_rest_parameter :: proc(t: ^testing.T) {
	// A rest parameter arrives as one array and a positional one as a value, so the two signatures
	// are called differently and neither is the other.
	expect_errors(
		t,
		`const spread: (...xs: number[]) => number = (a: number[]): number => a.length;`,
		[]Error{{.Type_Mismatch, 1, 45}},
	)
}

@(test)
a_required_parameter_does_not_fit_an_optional_one :: proc(t: ^testing.T) {
	// The target may leave the argument out, and then `undefined` arrives where the source asked
	// for a number.
	expect_errors(
		t,
		`const maybe: (a?: number) => void = (a: number): void => {};`,
		[]Error{{.Type_Mismatch, 1, 37}},
	)
}

@(test)
an_arrow_parameter_from_an_optional_one_may_be_undefined :: proc(t: ^testing.T) {
	// The call may leave the argument out, so the body sees `number | undefined` and has to say
	// what it does about it.
	expect_errors(
		t,
		lines(
			`function run(cb: (x?: number) => number): number { return cb(); }`, //
			`const answer = run(x => x + 1);`,
		),
		[]Error{{.Addition_Operands, 2, 25}},
	)
}

@(test)
an_arrow_that_tests_an_optional_parameter_fits :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function run(cb: (x?: number) => number): number { return cb(); }`, //
			`const answer = run(x => x === undefined ? 0 : x);`,
		),
	)
}

// A context behind `| undefined`.

@(test)
an_arrow_reads_the_signature_of_an_optional_callback :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function run(cb?: (x: number) => number): number {`, //
			`return cb === undefined ? 0 : cb(1);`,
			`}`,
			`const answer = run(x => x + 1);`,
		),
	)
}

// The expected result of an arrow.

@(test)
the_expected_result_reaches_the_body_of_an_arrow :: proc(t: ^testing.T) {
	// Without it the object literal has no context and `kind` widens to `string`, which no longer
	// fits the member of the union it was written for.
	c := expect_checked(
		t,
		lines(
			`interface Circle { kind: "circle"; r: number; }`, //
			`const make: (r: number) => Circle = r => ({ kind: "circle", r: r });`,
			`const pick: () => "a" | "b" = () => "a";`,
		),
	)

	testing.expect_value(t, declared_text(c, "make"), "(r: number) => Circle")
	testing.expect_value(t, declared_text(c, "pick"), `() => "a" | "b"`)
}
