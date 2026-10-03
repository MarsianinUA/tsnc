package opt_tests

import "core:testing"

import "../../src/ir"
import "../harness"

@(test)
the_body_of_a_small_callee_replaces_its_call :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function at(values: number[], i: number): number {
			if (i < 0) {
				return 0;
			}
			return values[i];
		}
		function sum(values: number[]): number {
			let total = 0;
			for (let i = 0; i < 3; i++) {
				total += at(values, i - 1);
			}
			return total;
		}
		console.log(sum([1, 2, 3]));
	`,
	)
	at := harness.func_named(t, result.output, "m1.at")
	sum := harness.func_named(t, result.output, "m1.sum")
	_, calls := placed_of(sum, ir.Call)
	testing.expectf(t, len(calls) == 0, "%s", result.after)

	// The two returns meet in a phi, and the copied check fails where the callee's own does.
	ids, phis := placed_of(sum, ir.Phi)
	joined := false
	for phi in phis {
		for edge in phi.incoming {
			_, is_load := sum.values[read_as(sum, edge.value)].variant.(ir.Element_Load)
			joined ||= is_load && len(phi.incoming) == 2
		}
	}
	testing.expectf(t, joined, "no phi of the returns among %v:\n%s", ids, result.after)
	_, own := placed_of(at, ir.Bounds_Check)
	_, copied := placed_of(sum, ir.Bounds_Check)
	if testing.expectf(t, len(own) == 1 && len(copied) == 1, "%s", result.after) {
		testing.expect(t, own[0].not_integer == copied[0].not_integer)
		testing.expect(t, own[0].out_of_range == copied[0].out_of_range)
	}
}

@(test)
a_callee_over_the_limit_or_one_that_calls_itself_stays_a_call :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function fact(n: number): number {
			return n < 2 ? 1 : n * fact(n - 1);
		}
		function long(x: number): number {
			let y = x;
			y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1;
			y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1;
			y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1;
			y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1;
			y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1;
			y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1; y = y * 3 + 1;
			return y;
		}
		function looped(n: number): number {
			let s = 0;
			for (let i = 0; i < n; i++) {
				s += i;
			}
			return s;
		}
		function main(): void {
			console.log(fact(5), long(2), looped(4));
		}
		main();
	`,
	)
	main := harness.func_named(t, result.output, "m1.main")
	_, calls := placed_of(main, ir.Call)
	called: [dynamic]string
	called.allocator = context.temp_allocator
	for call in calls {
		append(&called, result.output.funcs[call.func].name)
	}
	testing.expectf(
		t,
		len(called) == 3 &&
		called[0] == "m1.fact" &&
		called[1] == "m1.long" &&
		called[2] == "m1.looped",
		"%v:\n%s",
		called,
		result.after,
	)
}
