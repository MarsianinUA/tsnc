package lower_tests

import "core:slice"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

// Which modules run, and in what order. program.init_order lists every file of the table once, the
// lib among them and a module nothing loads as well, so the filter lower applies is the whole of
// this file.

@(test)
modules_run_after_the_ones_they_import :: proc(t: ^testing.T) {
	result := lower_sources(
		t,
		{
			`
			import { two } from "./m2";
			console.log(two());
			`,
			`
			import { three } from "./m3";
			export function two(): number {
				return three() - 1;
			}
			`,
			`
			export function three(): number {
				return 3;
			}
			`,
		},
	)
	testing.expect(t, len(result.errors) == 0, "lower reported something")
	want := []string{"init$m3", "init$m2", "init$m1"}
	testing.expectf(
		t,
		slice.equal(init_names(result.output), want),
		"%v",
		init_names(result.output),
	)
}

@(test)
the_lib_never_initializes :: proc(t: ^testing.T) {
	result := lower_text(t, "console.log(1);")
	testing.expectf(
		t,
		slice.equal(init_names(result.output), []string{"init$m1"}),
		"%v",
		init_names(result.output),
	)
}

@(test)
a_module_only_an_import_type_reaches_never_runs :: proc(t: ^testing.T) {
	// m2 is reached by a value import and runs; m3 only types a name, and Node never loads it, so
	// its top-level code must not run either.
	result := lower_sources(
		t,
		{
			`
			import { size } from "./m2";
			import type { Shape } from "./m3";
			const s: Shape = size;
			console.log(s);
			`,
			`
			export const size = 7;
			`,
			`
			export type Shape = number;
			console.log("m3 loaded");
			`,
		},
	)
	testing.expect(t, len(result.errors) == 0, "lower reported something")
	want := []string{"init$m2", "init$m1"}
	testing.expectf(
		t,
		slice.equal(init_names(result.output), want),
		"%v",
		init_names(result.output),
	)
}

@(test)
a_module_nothing_imports_never_runs :: proc(t: ^testing.T) {
	// m2 is in the file table and nobody reaches it. The graph still orders it, and lower drops it.
	result := lower_sources(t, {`console.log(1);`, `console.log("never");`})
	testing.expect(t, len(result.errors) == 0, "lower reported something")
	testing.expectf(
		t,
		slice.equal(init_names(result.output), []string{"init$m1"}),
		"%v",
		init_names(result.output),
	)
}

@(test)
main_calls_every_init_in_order :: proc(t: ^testing.T) {
	result := lower_sources(
		t,
		{
			`import { two } from "./m2";
		console.log(two());`,
			`export function two(): number {
			return 2;
		}`,
		},
	)
	main, found := func_named(result.output, abi.MAIN_SYMBOL)
	testing.expect(t, found, "there is no entry point")
	testing.expect(
		t,
		len(main.params) == 0 && main.result == ir.VOID,
		"the entry point has a signature",
	)

	called := make([dynamic]string, context.temp_allocator)
	for instruction in main.values {
		if call, is_call := instruction.variant.(ir.Call); is_call {
			append(&called, result.output.funcs[call.func].name)
		}
	}
	testing.expectf(t, slice.equal(called[:], []string{"init$m2", "init$m1"}), "%v", called[:])
}

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

@(test)
an_imported_binding_is_the_other_modules_global :: proc(t: ^testing.T) {
	result := lower_sources(
		t,
		{`import { size } from "./m2";
		console.log(size);`, `export const size = 7;`},
	)
	init, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")

	read := false
	for instruction in init.values {
		if load, is_load := instruction.variant.(ir.Global_Load); is_load {
			read ||= result.output.globals[load.global].name == "m2.size"
		}
	}
	testing.expect(t, read, "the import did not read the global of the other module")
}
