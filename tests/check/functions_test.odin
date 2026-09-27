package check_tests

import "core:testing"

// Rest and optional parameters.

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
