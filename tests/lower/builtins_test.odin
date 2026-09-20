package lower_tests

import "core:slice"
import "core:testing"

import "../../src/abi"
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
math_constants_are_constants :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		const half = Math.PI / 2;
		const wide = Infinity;
		const none = NaN;
		console.log(half, wide, none);
	`,
	)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	pi := false
	for instruction in init.values {
		if number, is_number := instruction.variant.(ir.Const_Number); is_number {
			pi ||= number.value == 3.141592653589793
		}
	}
	testing.expectf(t, pi, "%s", result.text)
	testing.expect(t, runtime_calls(init, .Math_Round) == 0)
}

@(test)
round_max_and_min_go_to_the_runtime :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function pick(a: number, b: number, c: number): number {
			return Math.round(Math.max(a, b, c) - Math.min(a, b));
		}
		pick(1, 2, 3);
	`,
	)
	body, found := func_named(result.output, "m1.pick")
	testing.expect(t, found, "the function was not lowered")
	testing.expectf(t, runtime_calls(body, .Math_Round) == 1, "%s", result.text)
	// Three arguments fold two at a time, so max is two calls and min is one.
	testing.expectf(t, runtime_calls(body, .Math_Max) == 2, "%s", result.text)
	testing.expectf(t, runtime_calls(body, .Math_Min) == 1, "%s", result.text)
}

@(test)
max_of_nothing_is_the_identity_of_the_fold :: proc(t: ^testing.T) {
	result := lower_text(t, `
		const nothing = Math.max();
		console.log(nothing);
	`)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expect(t, runtime_calls(init, .Math_Max) == 0)
	lowest := false
	for instruction in init.values {
		if number, is_number := instruction.variant.(ir.Const_Number); is_number {
			lowest ||= number.value < 0 && number.value == number.value / 2
		}
	}
	testing.expectf(t, lowest, "%s", result.text)
}

@(test)
number_is_integer_tests_the_value_and_its_bound :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function whole(x: number): boolean {
			return Number.isInteger(x);
		}
		whole(1);
	`,
	)
	body, found := func_named(result.output, "m1.whole")
	testing.expect(t, found, "the function was not lowered")
	testing.expectf(
		t,
		slice.equal(intrinsics_of(body), []ir.Intrinsic_Op{.Trunc, .Abs}),
		"%s",
		result.text,
	)
	phis := 0
	for instruction in body.values {
		if _, is_phi := instruction.variant.(ir.Phi); is_phi {
			phis += 1
		}
	}
	testing.expectf(t, phis == 1, "%s", result.text)
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

@(test)
console_log_writes_one_call_per_piece :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log(1, "a", true);`)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	// Two separators and the line end, plus the string argument.
	testing.expectf(t, runtime_calls(init, .Console_String) == 4, "%s", result.text)
	testing.expectf(t, runtime_calls(init, .Console_Number) == 1, "%s", result.text)
	testing.expectf(t, runtime_calls(init, .Console_Boolean) == 1, "%s", result.text)
}

@(test)
console_log_of_nothing_is_a_line_end :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log();`)
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, runtime_calls(init, .Console_String) == 1, "%s", result.text)
}

@(test)
null_and_undefined_print_as_words :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log(null, undefined);`)
	init, _ := func_named(result.output, "init$m1")
	// The two words, the separator and the line end.
	testing.expectf(t, runtime_calls(init, .Console_String) == 4, "%s", result.text)
	testing.expectf(t, runtime_calls(init, .Console_Number) == 0, "%s", result.text)
}

@(test)
console_error_writes_to_the_other_stream :: proc(t: ^testing.T) {
	result := lower_text(t, `console.error("bad");`)
	init, _ := func_named(result.output, "init$m1")
	streams := make([dynamic]bool, context.temp_allocator)
	for instruction in init.values {
		if call, is_call := instruction.variant.(ir.Call_Runtime); is_call {
			flag := init.values[call.args[0]].variant.(ir.Const_Bool)
			append(&streams, flag.value)
		}
	}
	testing.expectf(t, len(streams) == 2, "%s", result.text)
	testing.expectf(t, streams[0] && streams[1], "%s", result.text)
}

@(test)
process_exit_never_comes_back :: proc(t: ^testing.T) {
	result := lower_text(t, `
		console.log(1);
		process.exit(2);
	`)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expectf(t, runtime_calls(init, .Process_Exit) == 1, "%s", result.text)

	last := init.blocks[len(init.blocks) - 1].instructions
	_, ends := init.values[last[len(last) - 1]].variant.(ir.Unreachable)
	testing.expectf(t, ends, "%s", result.text)
}

@(test)
process_exit_without_a_code_exits_with_zero :: proc(t: ^testing.T) {
	result := lower_text(t, `process.exit();`)
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, runtime_calls(init, .Process_Exit) == 1, "%s", result.text)
}

@(test)
typeof_folds_to_the_word_for_a_static_type :: proc(t: ^testing.T) {
	// check types `typeof x` as the union of the words the operator can answer. Every member of
	// that union is a string, so the value is a plain string and not a tagged one, and the operand
	// already has a type, so the answer is a constant and no tag is read at run time.
	result := lower_text(
		t,
		"const a = typeof 1;\nconst b = typeof true;\nconst c = typeof \"x\";\nconsole.log(a, b, c);\n",
	)
	testing.expect(t, result.output.globals[0].type == ir.STR)
	words := pool_words(result.output)
	for want in ([]string{"number", "boolean", "string"}) {
		testing.expectf(t, slice.contains(words, want), "the pool has no %q: %v", want, words)
	}
}

@(test)
a_template_with_no_substitution_is_a_string_literal :: proc(t: ^testing.T) {
	// lower_text answers only for a program lower said nothing about, so reaching the pool at all
	// means the template compiled. parse cooks a template into its parts, so one that substitutes
	// nothing is a finished string: it interns as the same text the quoted spelling does, once.
	result := lower_text(
		t,
		"const greeting = `hi`;\nconst same = \"hi\";\nconsole.log(greeting, same);\n",
	)
	words := pool_words(result.output)
	appearances := 0
	for word in words {
		if word == "hi" {
			appearances += 1
		}
	}
	testing.expectf(
		t,
		appearances == 1,
		"%q is in the pool %d times: %v",
		"hi",
		appearances,
		words,
	)
}

// What this build refuses. Each construct is named once, where it stands.

@(test)
objects_are_reported_once :: proc(t: ^testing.T) {
	expect_later(t, "const p = { x: 1 };\nconsole.log(p.x);\n", {{.Not_Lowered, 1, 7}})
}

@(test)
arrays_are_reported :: proc(t: ^testing.T) {
	expect_later(t, "const xs = [1, 2];\n", {{.Not_Lowered, 1, 7}})
}

@(test)
template_substitution_and_joining_are_reported :: proc(t: ^testing.T) {
	expect_later(
		t,
		"const a = `x${1}`;\nconst b = \"a\" + \"b\";\n",
		{{.Not_Lowered, 1, 11}, {.Not_Lowered, 2, 11}},
	)
}

@(test)
an_arrow_function_is_reported :: proc(t: ^testing.T) {
	expect_later(t, "const f = (x: number): number => x;\n", {{.Not_Lowered, 1, 7}})
}

@(test)
the_four_math_names_the_ir_cannot_say_are_reported :: proc(t: ^testing.T) {
	expect_later(t, "console.log(Math.hypot(3, 4));\n", {{.Not_Lowered, 1, 13}})
}

@(test)
string_methods_and_process_argv_are_reported :: proc(t: ^testing.T) {
	expect_later(
		t,
		"const n = \"abc\".length;\nconst v = process.argv;\n",
		{{.Not_Lowered, 1, 11}, {.Not_Lowered, 2, 7}},
	)
}

@(test)
a_union_is_reported_where_it_is_used :: proc(t: ^testing.T) {
	// The binding itself is a tagged value, which lower holds and stores; everything that reads a
	// number back out of it is the tag check of milestone 5.
	result := expect_later(
		t,
		"let x: number | undefined = 1;\nconsole.log(x);\n",
		{{.Not_Lowered, 2, 13}},
	)
	testing.expect(t, len(result.output.globals) == 1)
	testing.expect(t, result.output.globals[0].type == ir.TAGGED)
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

@(private = "file")
runtime_calls :: proc(body: ir.Func, export: abi.Runtime_Proc) -> int {
	total := 0
	for instruction in body.values {
		if call, is_call := instruction.variant.(ir.Call_Runtime);
		   is_call && call.export == export {
			total += 1
		}
	}
	return total
}
