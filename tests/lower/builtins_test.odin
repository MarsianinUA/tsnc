package lower_tests

import "core:slice"
import "core:strings"
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
	testing.expect(t, calls_to(init, .Math_Round) == 0)
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
	testing.expectf(t, calls_to(body, .Math_Round) == 1, "%s", result.text)
	// Three arguments fold two at a time, so max is two calls and min is one.
	testing.expectf(t, calls_to(body, .Math_Max) == 2, "%s", result.text)
	testing.expectf(t, calls_to(body, .Math_Min) == 1, "%s", result.text)
}

@(test)
max_of_nothing_is_the_identity_of_the_fold :: proc(t: ^testing.T) {
	result := lower_text(t, `
		const nothing = Math.max();
		console.log(nothing);
	`)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expect(t, calls_to(init, .Math_Max) == 0)
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
console_log_is_one_runtime_call_per_statement :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log(1, "a", true);`)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	call, called := only_console_call(init)
	if !testing.expectf(t, called, "%s", result.text) {
		return
	}
	// The stream, then every argument as a tagged value.
	testing.expectf(t, len(call.args) == 4, "%s", result.text)
	for arg in call.args[1:] {
		testing.expectf(t, init.values[arg].type == ir.TAGGED, "%s", result.text)
	}
}

// Node evaluates the whole list before it writes anything, so the call an argument makes comes
// ahead of the write of its statement.
@(test)
console_log_evaluates_every_argument_before_it_writes :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function two(): number {
			return 2;
		}
		console.log(1, two());
	`,
	)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	called := false
	for instruction in init.values {
		#partial switch _ in instruction.variant {
		case ir.Call:
			called = true
		case ir.Call_Runtime:
			testing.expectf(t, called, "%s", result.text)
		}
	}
	testing.expectf(t, called, "%s", result.text)
}

@(test)
console_log_of_nothing_passes_no_values :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log();`)
	init, _ := func_named(result.output, "init$m1")
	call, called := only_console_call(init)
	testing.expectf(t, called && len(call.args) == 1, "%s", result.text)
}

@(test)
null_and_undefined_pass_as_constants :: proc(t: ^testing.T) {
	result := lower_text(t, `console.log(null, undefined);`)
	init, _ := func_named(result.output, "init$m1")
	call, called := only_console_call(init)
	if !testing.expectf(t, called && len(call.args) == 3, "%s", result.text) {
		return
	}
	_, is_null := init.values[call.args[1]].variant.(ir.Const_Null)
	_, is_undefined := init.values[call.args[2]].variant.(ir.Const_Undefined)
	testing.expectf(t, is_null && is_undefined, "%s", result.text)
}

@(test)
console_log_prints_a_union :: proc(t: ^testing.T) {
	result := lower_text(t, "let x: number | undefined = 1;\nconsole.log(x);\n")
	init, _ := func_named(result.output, "init$m1")
	_, called := only_console_call(init)
	testing.expectf(t, called, "%s", result.text)
}

@(test)
console_error_writes_to_the_other_stream :: proc(t: ^testing.T) {
	result := lower_text(t, `console.error("bad");`)
	init, _ := func_named(result.output, "init$m1")
	call, called := only_console_call(init)
	if !testing.expectf(t, called, "%s", result.text) {
		return
	}
	stream := init.values[call.args[0]].variant.(ir.Const_Bool)
	testing.expectf(t, stream.value, "%s", result.text)
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

@(test)
process_exit_never_comes_back :: proc(t: ^testing.T) {
	result := lower_text(t, `
		console.log(1);
		process.exit(2);
	`)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expectf(t, calls_to(init, .Process_Exit) == 1, "%s", result.text)

	last := init.blocks[len(init.blocks) - 1].instructions
	_, ends := init.values[last[len(last) - 1]].variant.(ir.Unreachable)
	testing.expectf(t, ends, "%s", result.text)
}

@(test)
process_exit_without_a_code_exits_with_zero :: proc(t: ^testing.T) {
	result := lower_text(t, `process.exit();`)
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, calls_to(init, .Process_Exit) == 1, "%s", result.text)
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
typeof_a_function_is_the_word_function :: proc(t: ^testing.T) {
	// The type of the name already says what `typeof` answers, and reading the name runs nothing,
	// so no closure is made.
	result := lower_text(t, "function one(): number {\n\treturn 1;\n}\nconsole.log(typeof one);\n")
	words := pool_words(result.output)
	testing.expectf(t, slice.contains(words, "function"), "the pool has no function: %v", words)
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

// The constructs milestone 5 opened, in their plainest form; objects_test.odin, arrays_test.odin
// and strings_test.odin hold the rest.

@(test)
an_object_is_a_cell_and_its_fields :: proc(t: ^testing.T) {
	result := lower_text(t, "const p = { x: 1 };\nconsole.log(p.x);\n")
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expectf(t, len(instructions_of(init, ir.Alloc)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Field_Store)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Field_Load)) == 1, "%s", result.text)
}

@(test)
an_array_is_made_at_its_length_and_filled :: proc(t: ^testing.T) {
	result := lower_text(t, "const xs = [1, 2];\nconsole.log(xs);\n")
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expectf(t, len(instructions_of(init, ir.New_Array)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Element_Store)) == 2, "%s", result.text)
}

@(test)
a_template_and_a_joined_string_go_to_the_runtime :: proc(t: ^testing.T) {
	result := lower_text(t, "const a = `x${1}`;\nconst b = \"a\" + \"b\";\nconsole.log(a, b);\n")
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expectf(t, calls_to(init, .Number_To_String) == 1, "%s", result.text)
	testing.expectf(t, calls_to(init, .String_Concat) == 2, "%s", result.text)
}

@(test)
string_length_and_process_argv_lower :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"const n = \"abc\".length;\nconst v = process.argv;\nconsole.log(n, v);\n",
	)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	testing.expectf(t, len(instructions_of(init, ir.Length)) == 1, "%s", result.text)
	v := result.output.globals[1]
	testing.expect_value(t, v.name, "m1.v")
	testing.expect_value(t, v.type.kind, ir.Type_Kind.Ref)
	testing.expect_value(t, result.output.layouts[v.type.layout].element, abi.Slot_Kind.Ref)
}

// What this build refuses. Each construct is named once, where it stands.

@(test)
an_arrow_function_is_a_new_closure :: proc(t: ^testing.T) {
	result := lower_text(t, "const f = (x: number): number => x;\nconsole.log(f(2));\n")
	init, _ := func_named(result.output, "init$m1")
	made := instructions_of(init, ir.Make_Closure)
	if !testing.expectf(t, len(made) == 1, "%s", result.text) {
		return
	}
	arrow := result.output.funcs[made[0].func]
	info, described := arrow.info.?
	testing.expectf(t, described && strings.has_prefix(arrow.name, "m1.f$"), "%s", result.text)
	testing.expect(t, info.length == 1 && !info.has_prototype)
	testing.expect_value(t, pool_words(result.output)[info.name], "f")
}

@(test)
the_four_math_names_the_ir_cannot_say_are_reported :: proc(t: ^testing.T) {
	expect_later(t, "console.log(Math.hypot(3, 4));\n", {{.Not_Lowered, 1, 13}})
}


@(test)
a_non_null_assertion_tests_the_tag_before_the_number_is_read :: proc(t: ^testing.T) {
	// The binding itself is a tagged value. `x!` fails where it is null or undefined, at the start
	// of `x!`, and the number is then unboxed after a test of its own tag.
	result := lower_text(
		t,
		"let x: number | undefined = 1;\nfunction f(): number {\nreturn x! + 1;\n}\n",
	)
	testing.expect(t, len(result.output.globals) == 1)
	testing.expect(t, result.output.globals[0].type == ir.TAGGED)

	body, _ := func_named(result.output, "m1.f")
	tests := instructions_of(body, ir.Tag_Test)
	fails := instructions_of(body, ir.Fail)
	if !testing.expectf(t, len(tests) == 2 && len(fails) == 2, "%s", result.text) {
		return
	}
	testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Undefined, .Null})
	testing.expect_value(t, tests[1].tags, ir.Tag_Set{.Number})
	non_null := result.output.fail_sites[fails[0].site]
	testing.expect_value(t, non_null.error, abi.Runtime_Error.Non_Null_Assertion)
	testing.expect_value(t, non_null.line, 3)
	testing.expect_value(t, non_null.column, 8)
	kind := result.output.fail_sites[fails[1].site].error
	testing.expect_value(t, kind, abi.Runtime_Error.Tagged_Holds_Other_Kind)
	testing.expectf(t, len(instructions_of(body, ir.Unbox)) == 1, "%s", result.text)
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
only_console_call :: proc(body: ir.Func) -> (call: ir.Call_Runtime, found: bool) {
	if calls_to(body, .Console_Log) != 1 {
		return {}, false
	}
	for instruction in body.values {
		if runtime, is_runtime := instruction.variant.(ir.Call_Runtime); is_runtime {
			if runtime.export == .Console_Log {
				return runtime, true
			}
		}
	}
	return {}, false
}
