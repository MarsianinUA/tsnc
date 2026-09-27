package check_tests

import "core:testing"

// A function converted to a string (T2028) and an operation on `any` that JavaScript carries out by
// converting the value or looking something up at run time (T2029), which tsnc does not do.

@(test)
a_union_that_may_hold_a_function_is_converted_at_run_time :: proc(t: ^testing.T) {
	// The runtime refuses the function where the value turns out to be one.
	expect_checked(
		t,
		lines(
			`function show(v: (() => number) | string): string {`, //
			"return `${v}` + v + String(v);",
			`}`,
		),
	)
}
