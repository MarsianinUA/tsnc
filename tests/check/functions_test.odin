package check_tests

import "core:testing"

@(test)
a_call_gives_back_the_result_of_the_signature :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function twice(n: number): string { return "x"; }`, //
			`const answer = twice(21);`,
		),
	)

	testing.expect_value(t, declared_text(c, "answer"), "string")
}

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
an_optional_parameter_may_be_left_out :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`function greet(name: string, loud?: boolean): string { return name; }`, //
			`const plain = greet("a");`,
			`const shouted = greet("a", true);`,
			`const spelled = greet("a", undefined);`,
		),
	)
}

@(test)
an_optional_parameter_is_undefined_inside_the_body :: proc(t: ^testing.T) {
	// A call may leave it out, so the body has to reckon with it being absent.
	c := expect_checked(t, `function greet(loud?: boolean): string { return typeof loud; }`)
	testing.expect_value(t, use_text(c, "loud"), "boolean | undefined")
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
calling_a_value_that_is_not_a_function_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const count = 1;`, //
			`const answer = count();`,
		),
		[]Error{{.Not_Callable, 2, 16}},
	)
}

@(test)
a_function_is_a_value_with_a_type_of_its_own :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`function twice(n: number): number { return n * 2; }`, //
			`const held: (n: number) => number = twice;`,
			`const answer = held(21);`,
		),
	)

	testing.expect_value(t, declared_text(c, "held"), "(n: number) => number")
	testing.expect_value(t, declared_text(c, "answer"), "number")
}

@(test)
a_function_fits_where_it_is_asked_for_less :: proc(t: ^testing.T) {
	// Every call the target allows has to be a call the source accepts, so a function that reads
	// fewer arguments fits, and one that hands back more than is wanted fits too.
	expect_checked(
		t,
		lines(
			`const ignores: (a: number, b: number) => void = (a: number) => {};`, //
			`const returns: (a: number) => void = (a: number): number => a;`,
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

@(test)
a_result_a_call_reads_a_type_variable_out_of_is_still_inferred :: proc(t: ^testing.T) {
	// `map<U>` works out `U` from the body, so a result holding a type variable gives no context.
	c := expect_checked(
		t,
		lines(
			`const xs: number[] = [1, 2, 3];`, //
			`const doubled = xs.map(x => x * 2);`,
			`const texts = xs.map(x => "n");`,
		),
	)

	testing.expect_value(t, declared_text(c, "doubled"), "number[]")
	testing.expect_value(t, declared_text(c, "texts"), "string[]")
}
