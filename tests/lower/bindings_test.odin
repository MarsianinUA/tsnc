package lower_tests

import "core:strings"
import "core:testing"

import "../../src/ir"
import "../harness"

// Bindings: where a name lives, and what it holds before anything is written to it.

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
	count := harness.global_named(t, result.output, "m1.count")
	name := harness.global_named(t, result.output, "m1.name")
	testing.expectf(t, count.type == ir.F64 && name.type == ir.STR, "%s", result.text)
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
	init := harness.func_named(t, result.output, "init$m1")

	count, is_number := first_store(result.output, init, "m1.count").(ir.Const_Number)
	testing.expectf(t, is_number && count.value == 0, "%s", result.text)
	flag, is_bool := first_store(result.output, init, "m1.flag").(ir.Const_Bool)
	testing.expectf(t, is_bool && !flag.value, "%s", result.text)
	// A string binding takes the empty cell rather than a null pointer.
	empty, is_string := first_store(result.output, init, "m1.text").(ir.Const_String)
	testing.expectf(t, is_string && len(result.output.strings[empty.text]) == 0, "%s", result.text)
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
	step := harness.global_named(t, result.output, "m1.step")
	maybe := harness.global_named(t, result.output, "m1.maybe")
	testing.expectf(t, step.type == ir.F64 && maybe.type == ir.TAGGED, "%s", result.text)

	body := harness.func_named(t, result.output, "m1.pick")
	testing.expect(t, body.result == ir.F64)
	testing.expectf(t, len(instructions_of(body, ir.Box)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Tag_Test)) == 0, "%s", result.text)
}

@(test)
a_read_made_after_the_declaration_needs_no_check :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		const scale = 2;
		const twice = (n: number): number => n * scale;
		console.log(twice(3));
	`,
	)
	for body in result.output.funcs {
		testing.expectf(t, len(instructions_of(body, ir.Null_Test)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Fail)) == 0, "%s", result.text)
	}
	for global in result.output.globals {
		testing.expectf(t, !strings.has_suffix(global.name, "$ready"), "%s", result.text)
	}
}

// first_store is the value the entry block of init stores into the global first, which is before
// any statement of the module runs.
@(private = "file")
first_store :: proc(output: ir.Program_IR, init: ir.Func, name: string) -> ir.Variant {
	for id in init.blocks[ir.ENTRY].instructions {
		store, is_store := init.values[id].variant.(ir.Global_Store)
		if is_store && output.globals[store.global].name == name {
			return init.values[store.value].variant
		}
	}
	return ir.Unreachable{}
}
