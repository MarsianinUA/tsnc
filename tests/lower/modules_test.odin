package lower_tests

import "core:slice"
import "core:testing"

import "../../src/ir"

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
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")

	names := make([dynamic]string, context.temp_allocator)
	for instruction in init.values {
		if call, is_call := instruction.variant.(ir.Call); is_call {
			append(&names, result.output.funcs[call.func].name)
		}
	}
	testing.expectf(t, slice.contains(names[:], "m2.double"), "%v", names[:])
}
