package lower_tests

import "core:testing"

import "../../src/ir"

// Bindings: where a name lives, and what it holds before anything is written to it. The zero before
// use is the second leftover of the milestone 3 review that T4.3 owns.

@(test)
module_bindings_are_globals :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		let count = 0;
		const name = "tsnc";
		count = count + 1;
		console.log(name);
	`,
	)
	testing.expectf(t, len(result.output.globals) == 2, "%v", result.output.globals)
	testing.expect(t, result.output.globals[0].name == "m1.count")
	testing.expect(t, result.output.globals[0].type == ir.F64)
	testing.expect(t, result.output.globals[1].name == "m1.name")
	testing.expect(t, result.output.globals[1].type == ir.STR)
}

@(test)
every_global_is_zeroed_before_the_module_runs :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		let count: number;
		let flag: boolean;
		let text: string;
		count = 1;
	`,
	)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")

	// The first three stores are the zeroes, one per global, before any statement of the module.
	stores := make([dynamic]ir.Global_ID, context.temp_allocator)
	for instruction in init.values {
		if store, is_store := instruction.variant.(ir.Global_Store); is_store {
			append(&stores, store.global)
		}
	}
	testing.expectf(t, len(stores) == 4, "%s", result.text)
	testing.expect(t, stores[0] == 0 && stores[1] == 1 && stores[2] == 2, result.text)
	// A string binding takes the empty cell rather than a null pointer.
	testing.expect(t, len(result.output.strings) > 0 && len(result.output.strings[0]) == 0)
}

@(test)
a_union_of_one_representation_needs_no_tag :: proc(t: ^testing.T) {
	// `c ? 2 : 3` is typed `2 | 3`, and every member of that union is a number, so the value is a
	// number at run time. A union that can hold two shapes is the one that takes the tag.
	result := lower_text(
		t,
		`
		let step: 1 | 2 = 1;
		let maybe: number | undefined = 1;
		function pick(c: boolean): number {
			return c ? 2 : 3;
		}
		pick(true);
	`,
	)
	testing.expect(t, result.output.globals[0].type == ir.F64)
	testing.expect(t, result.output.globals[1].type == ir.TAGGED)

	body, found := func_named(result.output, "m1.pick")
	testing.expect(t, found, "the function was not lowered")
	for instruction in body.values {
		_, boxed := instruction.variant.(ir.Box)
		testing.expectf(t, !boxed, "a union of numbers was boxed: %s", result.text)
	}
}

@(test)
a_local_without_an_initializer_starts_at_its_zero :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function run(): number {
			let total: number;
			total = 5;
			return total;
		}
		run();
	`,
	)
	body, found := func_named(result.output, "m1.run")
	testing.expect(t, found, "the function was not lowered")
	first := body.values[body.blocks[ir.ENTRY].instructions[0]]
	number, is_number := first.variant.(ir.Const_Number)
	testing.expectf(t, is_number && number.value == 0, "%s", result.text)
}

@(test)
a_hoisted_function_may_read_a_binding_before_its_declaration :: proc(t: ^testing.T) {
	// Node throws a ReferenceError here and tsnc answers the zero of the binding, which the package
	// doc records. What matters is that it compiles and that the read is a plain load.
	result := lower_text(
		t,
		`
		function read(): number {
			return later;
		}
		console.log(read());
		let later = 3;
	`,
	)
	body, found := func_named(result.output, "m1.read")
	testing.expect(t, found, "the function was not lowered")
	loads := 0
	for instruction in body.values {
		if _, is_load := instruction.variant.(ir.Global_Load); is_load {
			loads += 1
		}
	}
	testing.expectf(t, loads == 1, "%s", result.text)
}

@(test)
a_parameter_is_the_value_the_builder_emitted :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function add(a: number, b: number): number {
			return a + b;
		}
		add(1, 2);
	`,
	)
	body, found := func_named(result.output, "m1.add")
	testing.expect(t, found, "the function was not lowered")
	testing.expect(t, len(body.params) == 2)
	testing.expect(t, body.params[0] == ir.F64 && body.params[1] == ir.F64)
	testing.expect(t, body.result == ir.F64)
}

@(test)
an_optional_parameter_is_tagged_and_defaults_to_undefined :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function greet(times?: number): number {
			return 1;
		}
		greet();
	`,
	)
	body, found := func_named(result.output, "m1.greet")
	testing.expect(t, found, "the function was not lowered")
	testing.expect(t, len(body.params) == 1 && body.params[0] == ir.TAGGED)

	init, has_init := func_named(result.output, "init$m1")
	testing.expect(t, has_init, "the module has no init function")
	filled := false
	for instruction in init.values {
		if _, is_undefined := instruction.variant.(ir.Const_Undefined); is_undefined {
			filled = true
		}
	}
	testing.expectf(t, filled, "%s", result.text)
}

@(test)
a_nested_function_without_captures_is_an_ordinary_function :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function outer(x: number): number {
			function twice(y: number): number {
				return y * 2;
			}
			return twice(x);
		}
		outer(2);
	`,
	)
	_, found := func_named(result.output, "m1.outer")
	testing.expect(t, found, "the outer function was not lowered")
	nested := false
	for body in result.output.funcs {
		nested ||= body.name != "m1.outer" && len(body.params) == 1 && body.result == ir.F64
	}
	testing.expect(t, nested, "the nested function was not lowered")
}

@(test)
a_function_that_captures_reads_its_environment :: proc(t: ^testing.T) {
	// x never changes, so the environment holds a copy of it.
	result := lower_text(
		t,
		`
		function outer(x: number): number {
			function inner(): number {
				return x;
			}
			return inner();
		}
		outer(1);
		`,
	)
	outer, _ := func_named(result.output, "m1.outer")
	for body in result.output.funcs {
		if body.name == "m1.outer" || body.env == ir.NO_LAYOUT {
			continue
		}
		fields := result.output.layouts[body.env].fields
		testing.expect(t, len(fields) == 1 && fields[0].kind == .Number)
		testing.expectf(t, len(instructions_of(body, ir.Env)) == 1, "%s", result.text)
	}
	testing.expectf(t, len(instructions_of(outer, ir.Make_Closure)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(outer, ir.Call_Closure)) == 1, "%s", result.text)
}
