package lower_tests

import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

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
	step, found := func_prefixed(result.output, "m1.step$")
	make, _ := func_named(result.output, "m1.make")
	if !testing.expectf(t, found && step.env != ir.NO_LAYOUT, "%s", result.text) {
		return
	}
	// In the order bind met them: the target of `count += n` first.
	testing.expectf(
		t,
		slice.equal(slot_kinds(result, step.env), []abi.Slot_Kind{.Ref, .Number}),
		"%s",
		result.text,
	)
	testing.expectf(t, len(instructions_of(step, ir.Env)) == 1, "%s", result.text)
	testing.expectf(
		t,
		len(instructions_of(make, ir.Alloc)) == 2,
		"a box and an env:\n%s",
		result.text,
	)
	testing.expectf(t, len(instructions_of(make, ir.Make_Closure)) == 1, "%s", result.text)
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
	fib, found := func_prefixed(result.output, "m1.fib$")
	fibs, _ := func_named(result.output, "m1.fibs")
	testing.expectf(t, found && fib.env == ir.NO_LAYOUT, "%s", result.text)
	testing.expectf(t, len(instructions_of(fib, ir.Call)) == 2, "%s", result.text)
	testing.expectf(t, len(instructions_of(fibs, ir.Call)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(fibs, ir.Make_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(fibs, ir.Alloc)) == 0, "%s", result.text)
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
	even, even_found := func_prefixed(result.output, "m1.even$")
	odd, odd_found := func_prefixed(result.output, "m1.odd$")
	parity, _ := func_named(result.output, "m1.parity")
	testing.expect(
		t,
		even_found && even.env == ir.NO_LAYOUT && len(instructions_of(even, ir.Call)) == 1,
	)
	testing.expect(
		t,
		odd_found && odd.env == ir.NO_LAYOUT && len(instructions_of(odd, ir.Call)) == 1,
	)
	testing.expectf(t, len(instructions_of(parity, ir.Make_Closure)) == 0, "%s", result.text)
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
	testing.expectf(t, len(result.errors) == 0, "lower %v", result.errors)
	init, _ := func_named(result.output, "init$m1")
	names := make([dynamic]string, context.temp_allocator)
	for ref in instructions_of(init, ir.Func_Ref) {
		body := result.output.funcs[ref.func]
		testing.expectf(t, body.info != nil, "%s is not described", body.name)
		append(&names, body.name)
	}
	testing.expectf(
		t,
		slice.equal(names[:], []string{"m2.triple", "m1.local", "m2.triple"}),
		"%v\n%s",
		names,
		result.text,
	)
	testing.expectf(t, len(instructions_of(init, ir.Call_Closure)) == 2, "%s", result.text)
}

@(test)
a_let_of_a_for_header_gets_a_box_per_pass :: proc(t: ^testing.T) {
	// One box where the scope opens, one after the init, one at the latch.
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
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, number_boxes(result, init) == 3, "%s", result.text)
	header_holds_a_box := false
	for instruction in init.values {
		if _, is_phi := instruction.variant.(ir.Phi); is_phi && instruction.type.kind == .Ref {
			header_holds_a_box = true
		}
	}
	testing.expectf(t, header_holds_a_box, "no phi joins the box:\n%s", result.text)
}

@(test)
sorting_with_a_comparator_passes_the_closure_as_it_stands :: proc(t: ^testing.T) {
	result := lower_text(t, "const xs = [2, 1];\nconsole.log(xs.sort((a, b) => a - b));\n")
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, calls_to(init, .Array_Sort) == 1, "%s", result.text)
	_, adapted := func_prefixed(result.output, "m1.sort$")
	testing.expectf(t, !adapted, "an adapter for a comparator that needs none:\n%s", result.text)
}

// func_prefixed finds a function whose name starts with the prefix, for a nested function or an
// arrow, whose name ends in a node number.
func_prefixed :: proc(output: ir.Program_IR, prefix: string) -> (ir.Func, bool) {
	for body in output.funcs {
		if strings.has_prefix(body.name, prefix) {
			return body, true
		}
	}
	return {}, false
}

slot_kinds :: proc(result: Lowered, layout: ir.Layout_ID) -> []abi.Slot_Kind {
	fields := result.output.layouts[layout].fields
	kinds := make([]abi.Slot_Kind, len(fields), context.temp_allocator)
	for field, i in fields {
		kinds[i] = field.kind
	}
	return kinds
}

// number_boxes counts the boxes a function makes for a number: environments of one Number slot.
number_boxes :: proc(result: Lowered, body: ir.Func) -> int {
	total := 0
	for alloc in instructions_of(body, ir.Alloc) {
		table := result.output.layouts[alloc.layout]
		one_number := len(table.fields) == 1 && table.fields[0].kind == .Number
		total += 1 if table.kind == .Environment && one_number else 0
	}
	return total
}
