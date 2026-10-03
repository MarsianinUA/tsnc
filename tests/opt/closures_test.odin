package opt_tests

import "core:testing"

import "../../src/ir"
import "../harness"

@(test)
a_call_through_a_closure_made_in_sight_is_direct :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function scaled(n: number, k: number): number {
			const sum = (m: number): number => {
				let s = 0;
				for (let i = 0; i < m; i++) {
					s += i * k;
				}
				return s;
			};
			return sum(n);
		}
		function twice(f: (x: number) => number, x: number): number {
			return f(f(x));
		}
		function shifted(x: number, k: number): number {
			return twice((y) => y + k, x);
		}
		console.log(scaled(4, 2), shifted(1, 3));
	`,
	)
	// The loop keeps sum a call. Its closure is not made, and its environment stays on the stack.
	scaled := harness.func_named(t, result.output, "m1.scaled")
	_, calls := placed_of(scaled, ir.Call)
	_, through := placed_of(scaled, ir.Call_Closure)
	_, closures := placed_of(scaled, ir.Make_Closure)
	direct := len(calls) == 1 && len(through) == 0 && len(closures) == 0
	if testing.expectf(t, direct && calls[0].env != ir.NO_VALUE, "%s", result.after) {
		env, is_alloc := scaled.values[calls[0].env].variant.(ir.Alloc)
		testing.expectf(t, is_alloc && env.place == .Stack, "%s", result.after)
	}

	// The arrow meets its calls in the copy of twice.
	shifted := harness.func_named(t, result.output, "m1.shifted")
	_, through = placed_of(shifted, ir.Call_Closure)
	_, closures = placed_of(shifted, ir.Make_Closure)
	testing.expectf(t, len(through) == 0 && len(closures) == 0, "%s", result.after)
}

@(test)
a_closure_through_a_phi_of_two_functions_stays_a_call_through_it :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function pick(flag: boolean, x: number): number {
			const f = flag ? (y: number) => y + 1 : (y: number) => y * 2;
			return f(x);
		}
		console.log(pick(true, 3), pick(false, 3));
	`,
	)
	pick := harness.func_named(t, result.output, "m1.pick")
	_, calls := placed_of(pick, ir.Call)
	_, through := placed_of(pick, ir.Call_Closure)
	if testing.expectf(t, len(calls) == 0 && len(through) == 1, "%s", result.after) {
		_, is_phi := pick.values[through[0].callee].variant.(ir.Phi)
		testing.expectf(t, is_phi, "%s", result.after)
	}
}
