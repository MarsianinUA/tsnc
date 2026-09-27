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
