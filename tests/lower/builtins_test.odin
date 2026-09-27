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
math_pow_is_the_power_operator :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function raise(x: number): number {
			return Math.pow(x, 2);
		}
		raise(3);
	`,
	)
	body, found := func_named(result.output, "m1.raise")
	testing.expect(t, found, "the function was not lowered")
	power := false
	for instruction in body.values {
		if binary, is_binary := instruction.variant.(ir.Binary); is_binary {
			power ||= binary.op == .Power
		}
	}
	testing.expectf(t, power, "%s", result.text)
}

@(test)
math_sign_answers_the_value_itself_at_zero :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function which(x: number): number {
			return Math.sign(x);
		}
		which(-2);
	`,
	)
	body, found := func_named(result.output, "m1.which")
	testing.expect(t, found, "the function was not lowered")
	for instruction in body.values {
		if phi, is_phi := instruction.variant.(ir.Phi); is_phi {
			// One arm per sign, and the third is the argument, which keeps a negative zero and a
			// NaN as they are.
			testing.expectf(t, len(phi.incoming) == 3, "%s", result.text)
		}
	}
}

// process.argv is one array for the whole run, made by main before any module runs.
@(test)
process_argv_is_a_global_main_fills_first :: proc(t: ^testing.T) {
	result := lower_text(t, "console.log(process.argv);\nconsole.log(process.argv);\n")
	testing.expectf(t, len(result.output.globals) == 1, "%s", result.text)
	argv := result.output.globals[0]
	testing.expectf(t, argv.type.kind == .Ref, "%s", result.text)
	testing.expectf(t, result.output.layouts[argv.type.layout].kind == .Array, "%s", result.text)
	testing.expectf(t, result.output.layouts[argv.type.layout].element == .Ref, "%s", result.text)

	main := result.output.funcs[result.output.main]
	entry := main.blocks[ir.ENTRY].instructions
	first, is_runtime := main.values[entry[0]].variant.(ir.Call_Runtime)
	testing.expectf(t, is_runtime && first.export == .Process_Argv, "%s", result.text)
	_, stores := main.values[entry[1]].variant.(ir.Global_Store)
	testing.expectf(t, stores, "%s", result.text)
	_, then_inits := main.values[entry[2]].variant.(ir.Call)
	testing.expectf(t, then_inits, "%s", result.text)

	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, calls_to(init, .Process_Argv) == 0, "%s", result.text)
}

@(test)
a_program_that_never_reads_process_argv_has_no_global_for_it :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log(1);`)
	testing.expectf(t, len(result.output.globals) == 0, "%s", result.text)
	main := result.output.funcs[result.output.main]
	testing.expectf(t, calls_to(main, .Process_Argv) == 0, "%s", result.text)
}

// What this build refuses. Each construct is named once, where it stands.

@(test)
the_four_math_names_the_ir_cannot_say_are_reported :: proc(t: ^testing.T) {
	expect_later(t, "console.log(Math.hypot(3, 4));\n", {{.Not_Lowered, 1, 13}})
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
