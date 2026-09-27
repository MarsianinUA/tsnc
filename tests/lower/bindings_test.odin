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
		testing.expectf(t, len(instructions_of(body, ir.Fail)) == 0, "%s", result.text)
	}
	testing.expect_value(t, len(result.output.globals), 2)
}
