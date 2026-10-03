package lower_tests

import "core:slice"
import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../harness"

// Closures: which functions take an environment, what it holds and how, and the calls through a
// function value, which pass the arguments of the callee's signature class.

@(test)
a_variable_that_never_changes_is_copied_and_one_that_does_is_boxed :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function make(n: number): () => number {
			let count = 0;
			const step = () => {
				count += n;
				return count;
			};
			return step;
		}
		console.log(make(2)());
	`,
	)
	step := harness.func_prefixed(t, result.output, "m1.step$")
	make := harness.func_named(t, result.output, "m1.make")
	if !testing.expectf(t, step.env != ir.NO_LAYOUT, "%s", result.text) {
		return
	}
	// n is copied in as a number, count is a reference to its box.
	testing.expectf(t, slot_kinds(result, step.env) == {.Number, .Ref}, "%s", result.text)
	boxes := 0
	for _, id in make.values {
		boxes += 1 if is_number_box(result, make, ir.Value_ID(id)) else 0
	}
	testing.expectf(t, boxes == 1, "%s", result.text)
}

@(test)
a_self_recursive_function_that_captures_nothing_is_called_directly :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function fibs(n: number): number {
			function fib(k: number): number {
				return k < 2 ? k : fib(k - 1) + fib(k - 2);
			}
			return fib(n);
		}
		console.log(fibs(10));
	`,
	)
	fib := harness.func_prefixed(t, result.output, "m1.fib$")
	fibs := harness.func_named(t, result.output, "m1.fibs")
	testing.expectf(t, fib.env == ir.NO_LAYOUT, "%s", result.text)
	for body in ([2]ir.Func{fib, fibs}) {
		testing.expectf(t, calls_function(result.output, body, "m1.fib$"), "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Make_Closure)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Alloc)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Call_Closure)) == 0, "%s", result.text)
	}
}

@(test)
two_nested_functions_that_only_call_each_other_are_called_directly :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function parity(n: number): boolean {
			function even(k: number): boolean {
				return k === 0 ? true : odd(k - 1);
			}
			function odd(k: number): boolean {
				return k === 0 ? false : even(k - 1);
			}
			return even(n);
		}
		console.log(parity(3));
	`,
	)
	even := harness.func_prefixed(t, result.output, "m1.even$")
	odd := harness.func_prefixed(t, result.output, "m1.odd$")
	parity := harness.func_named(t, result.output, "m1.parity")
	testing.expectf(t, even.env == ir.NO_LAYOUT, "%s", result.text)
	testing.expectf(t, odd.env == ir.NO_LAYOUT, "%s", result.text)
	testing.expectf(t, calls_function(result.output, even, "m1.odd$"), "%s", result.text)
	testing.expectf(t, calls_function(result.output, odd, "m1.even$"), "%s", result.text)
	testing.expectf(t, calls_function(result.output, parity, "m1.even$"), "%s", result.text)
	for body in ([3]ir.Func{even, odd, parity}) {
		testing.expectf(t, len(instructions_of(body, ir.Make_Closure)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Call_Closure)) == 0, "%s", result.text)
	}
}

@(test)
a_module_function_as_a_value_is_its_static_closure :: proc(t: ^testing.T) {
	sources := [?]string {
		`
		import { triple } from "./m2";
		function local(): number {
			return 1;
		}
		const f = triple;
		const g = local;
		console.log(f(1), g(), f === triple);
		`,
		`
		export function triple(x: number): number {
			return x * 3;
		}
		`,
	}
	result := lower_sources(t, sources[:])
	init := harness.func_named(t, result.output, "init$m1")
	names := make([dynamic]string, context.temp_allocator)
	for ref in instructions_of(init, ir.Func_Ref) {
		body := result.output.funcs[ref.func]
		testing.expectf(t, body.info != nil, "%s is not described", body.name)
		append(&names, body.name)
	}
	testing.expectf(t, slice.contains(names[:], "m2.triple"), "%s", result.text)
	testing.expectf(t, slice.contains(names[:], "m1.local"), "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Make_Closure)) == 0, "%s", result.text)
}

@(test)
a_declared_function_keeps_its_own_signature :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function fib(n: number): number {
			return n < 2 ? n : fib(n - 1) + fib(n - 2);
		}
		function each(items: number[], f: (x: number) => void): void {
			for (let i = 0; i < items.length; i++) f(items[i]);
		}
		let seen = 0;
		function note(x: number): number {
			seen += x;
			return seen;
		}
		each([1, 2, 3], note);
		console.log(fib(40), seen);
	`,
	)
	// note shares the key of its signature with fib, and its flow into a void type tags the result
	// of that class.
	fib := harness.func_named(t, result.output, "m1.fib")
	testing.expectf(t, fib.result == ir.F64, "%s", result.text)
	init := harness.func_named(t, result.output, "init$m1")
	refs := instructions_of(init, ir.Func_Ref)
	testing.expectf(t, len(refs) == 1, "%s", result.text)
	for ref in refs {
		adapter := result.output.funcs[ref.func]
		testing.expectf(
			t,
			adapter.result == ir.TAGGED && calls_function(result.output, adapter, "m1.note"),
			"note's value is not an adapter of its class:\n%s",
			result.text,
		)
	}
}

@(test)
a_let_of_a_for_header_gets_a_box_per_pass :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		const fs: (() => number)[] = [];
		for (let i = 0; i < 3; i++) {
			fs.push(() => i);
		}
		console.log(fs.length);
	`,
	)
	// The loop header joins the box of i: every edge into it, the back edge too, brings a box
	// made for the pass it starts.
	init := harness.func_named(t, result.output, "init$m1")
	renewed := false
	for instruction in init.values {
		phi := instruction.variant.(ir.Phi) or_continue
		fresh := len(phi.incoming) == 2 && phi.incoming[0].value != phi.incoming[1].value
		for edge in phi.incoming {
			fresh &&= is_number_box(result, init, edge.value)
		}
		renewed ||= fresh
	}
	testing.expectf(t, renewed, "no phi joins a new box per pass:\n%s", result.text)
}

@(test)
sorting_with_a_comparator_passes_the_closure_as_it_stands :: proc(t: ^testing.T) {
	result := lower_text(t, "const xs = [2, 1];\nconsole.log(xs.sort((a, b) => a - b));\n")
	init := harness.func_named(t, result.output, "init$m1")
	sorts := 0
	for call in instructions_of(init, ir.Call_Runtime) {
		if call.export != .Array_Sort {
			continue
		}
		sorts += 1
		// An adapter would carry the arrow's closure in its environment and call it.
		closure, is_closure := init.values[call.args[1]].variant.(ir.Make_Closure)
		arrow := result.output.funcs[closure.func]
		testing.expectf(
			t,
			is_closure &&
			closure.env == ir.NO_VALUE &&
			len(instructions_of(arrow, ir.Call_Closure)) == 0,
			"an adapter for a comparator that needs none:\n%s",
			result.text,
		)
	}
	testing.expectf(t, sorts > 0, "%s", result.text)
}

@(private = "file")
slot_kinds :: proc(result: Lowered, layout: ir.Layout_ID) -> bit_set[abi.Slot_Kind] {
	kinds: bit_set[abi.Slot_Kind]
	for field in result.output.layouts[layout].fields {
		kinds += {field.kind}
	}
	return kinds
}

// A box for a number is an environment of one Number slot.
@(private = "file")
is_number_box :: proc(result: Lowered, body: ir.Func, value: ir.Value_ID) -> bool {
	alloc := body.values[value].variant.(ir.Alloc) or_return
	table := result.output.layouts[alloc.layout]
	return table.kind == .Environment && len(table.fields) == 1 && table.fields[0].kind == .Number
}
