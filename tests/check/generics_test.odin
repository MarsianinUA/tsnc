package check_tests

import "core:testing"

// Instantiation of the generic built-in signatures, which requirements 2.2 gives v1 and
// requirements 5 asks to work out from the function a call passes.

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
