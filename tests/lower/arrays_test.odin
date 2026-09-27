package lower_tests

import "core:testing"

import "../../src/ir"

// Arrays: the four loops lower builds around a callback.

@(test)
the_four_callback_methods_are_loops_with_the_callback_inlined :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function sum(xs: number[]): number {
			let total = 0;
			xs.forEach((x, i) => {
				if (i > 5) {
					return;
				}
				total += x;
			});
			const doubled = xs.map(x => x * 2);
			const big = xs.filter(x => {
				if (x > 2) {
					return true;
				}
				return false;
			});
			return total + doubled.length + big.length + xs.reduce((a, b) => a + b, 0);
		}
		console.log(sum([1, 2, 3]));
	`,
	)
	body, _ := func_named(result.output, "m1.sum")
	testing.expectf(t, len(instructions_of(body, ir.Call)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Call_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Make_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Func_Ref)) == 0, "%s", result.text)
}

@(test)
a_callback_may_be_the_name_of_a_function :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function double(x: number): number {
			return x * 2;
		}
		console.log([1, 2].map(double));
	`,
	)
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, calls_function(result.output, init, "m1.double"), "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Func_Ref)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Call_Closure)) == 0, "%s", result.text)
}
