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
	testing.expectf(t, len(instructions_of(body, ir.Call_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.New_Array)) == 2, "%s", result.text)
	testing.expectf(t, calls_to(body, .Array_Push) == 1, "%s", result.text)
	// A bare return in forEach ends the pass, not the function: the one Return is the function's.
	testing.expectf(t, len(instructions_of(body, ir.Return)) == 1, "%s", result.text)
	// The filter callback's two returns meet in a phi.
	bools := 0
	for instruction in body.values {
		_, is_phi := instruction.variant.(ir.Phi)
		bools += 1 if is_phi && instruction.type == ir.BOOL else 0
	}
	testing.expectf(t, bools == 1, "%s", result.text)
}

@(test)
an_arrow_whose_switch_covers_every_case_runs_off_no_end :: proc(t: ^testing.T) {
	// check proves the end of each arrow unreachable (T3024). map used to refuse the arrow for the
	// value its end lacked, and reduce to keep its initial value on every pass.
	result := lower_text(
		t,
		`
		type K = "a" | "b";
		function score(ks: K[]): number {
			const scores = ks.map((k): number => {
				switch (k) {
					case "a":
						return 1;
					case "b":
						return 2;
				}
			});
			return scores.length + ks.reduce((total: number, k: K): number => {
				switch (k) {
					case "a":
						return total + 1;
					case "b":
						return total + 2;
				}
			}, 0);
		}
		console.log(score(["a", "b"]));
	`,
	)
	body, _ := func_named(result.output, "m1.score")
	// No callback assigns a local, so the only loop phis are the index and the accumulator, and
	// neither may take itself back.
	for instruction, id in body.values {
		phi, is_phi := instruction.variant.(ir.Phi)
		if !is_phi {
			continue
		}
		for incoming in phi.incoming {
			testing.expectf(t, incoming.value != ir.Value_ID(id), "%%%d:\n%s", id, result.text)
		}
	}
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
	calls := instructions_of(init, ir.Call)
	if testing.expectf(t, len(calls) == 1, "%s", result.text) {
		testing.expect_value(t, len(calls[0].args), 1)
	}
}
