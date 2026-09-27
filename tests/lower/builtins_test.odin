package lower_tests

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
	used: bit_set[ir.Intrinsic_Op]
	for call in instructions_of(body, ir.Intrinsic) {
		used += {call.op}
	}
	testing.expectf(t, used == {.Abs, .Sqrt, .Floor, .Atan2}, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
}

@(test)
a_program_that_never_reads_process_argv_has_no_global_for_it :: proc(t: ^testing.T) {
	// The program that reads it keeps the other half from passing on a global renamed.
	reads := lower_text(t, `console.log(process.argv.length);`)
	_, made := global_named(reads.output, "process.argv")
	testing.expectf(t, made, "%s", reads.text)

	result := lower_text(t, `console.log(1);`)
	_, made = global_named(result.output, "process.argv")
	testing.expectf(t, !made, "%s", result.text)
	for body in result.output.funcs {
		testing.expectf(t, calls_to(body, .Process_Argv) == 0, "%s", result.text)
	}
}
