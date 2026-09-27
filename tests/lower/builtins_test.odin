package lower_tests

import "core:slice"
import "core:testing"

import "../../src/ir"

// The standard library: what each strategy of the table actually emits, and what the build refuses
// to emit at all. lib_test.odin proves the table covers the lib; this file proves the rows work.

@(test)
math_names_with_an_intrinsic_use_it :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function work(x: number, y: number): number {
			return Math.floor(Math.sqrt(Math.abs(x))) + Math.atan2(x, y);
		}
		work(4, 2);
	`,
	)
	body, found := func_named(result.output, "m1.work")
	testing.expect(t, found, "the function was not lowered")
	testing.expectf(
		t,
		slice.equal(intrinsics_of(body), []ir.Intrinsic_Op{.Abs, .Sqrt, .Floor, .Atan2}),
		"%s",
		result.text,
	)
}

@(test)
a_program_that_never_reads_process_argv_has_no_global_for_it :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log(1);`)
	testing.expectf(t, len(result.output.globals) == 0, "%s", result.text)
	main := result.output.funcs[result.output.main]
	testing.expectf(t, calls_to(main, .Process_Argv) == 0, "%s", result.text)
}

@(private = "file")
intrinsics_of :: proc(body: ir.Func) -> []ir.Intrinsic_Op {
	out := make([dynamic]ir.Intrinsic_Op, context.temp_allocator)
	for instruction in body.values {
		if call, is_call := instruction.variant.(ir.Intrinsic); is_call {
			append(&out, call.op)
		}
	}
	return out[:]
}
