package lower_tests

import "core:testing"

import "../../src/ir"
import "../harness"

// A name another module declares: what a function from there lowers to.

@(test)
an_imported_function_is_called_directly :: proc(t: ^testing.T) {
	result := lower_sources(
		t,
		{
			`import { double } from "./m2";
		console.log(double(4));`,
			`export function double(x: number): number {
			return x * 2;
		}`,
		},
	)
	init := harness.func_named(t, result.output, "init$m1")
	testing.expectf(t, calls_function(result.output, init, "m2.double"), "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Func_Ref)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Make_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Call_Closure)) == 0, "%s", result.text)
}
