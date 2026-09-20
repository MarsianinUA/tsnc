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
