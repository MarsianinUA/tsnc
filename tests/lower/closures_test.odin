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
a_hoisted_declaration_reads_a_later_const_through_a_box :: proc(t: ^testing.T) {
	// The closure is made where the body opens, before `side` has its value, so it shares the box.
	result := lower_text(
		t,
		`
		function area(): number {
			function scaled(): number {
				return side * 2;
			}
			const side = 3;
			return scaled();
		}
		console.log(area());
	`,
	)
	scaled, found := func_prefixed(result.output, "m1.scaled$")
	area, _ := func_named(result.output, "m1.area")
	if !testing.expectf(t, found && scaled.env != ir.NO_LAYOUT, "%s", result.text) {
		return
	}
	testing.expect(t, slice.equal(slot_kinds(result, scaled.env), []abi.Slot_Kind{.Ref}))
	testing.expectf(t, len(instructions_of(area, ir.Call_Closure)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(area, ir.Call)) == 0, "%s", result.text)
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
a_recursive_arrow_reads_itself_through_a_box :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function factorial(n: number): number {
			const fact = (k: number): number => (k <= 1 ? 1 : k * fact(k - 1));
			return fact(n);
		}
		console.log(factorial(5));
	`,
	)
	fact, found := func_prefixed(result.output, "m1.fact$")
	factorial, _ := func_named(result.output, "m1.factorial")
	if !testing.expectf(t, found && fact.env != ir.NO_LAYOUT, "%s", result.text) {
		return
	}
	testing.expect(t, slice.equal(slot_kinds(result, fact.env), []abi.Slot_Kind{.Ref}))
	testing.expectf(t, len(instructions_of(fact, ir.Call_Closure)) == 1, "%s", result.text)
	stores := instructions_of(factorial, ir.Field_Store_Ref)
	stored_closure := false
	for store in stores {
		stored_closure ||= factorial.values[store.value].type == ir.CLOSURE
	}
	testing.expectf(t, stored_closure, "the closure never went into its box:\n%s", result.text)
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
a_boxed_for_of_variable_and_a_boxed_callback_parameter_are_bound_per_pass :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		const fs: (() => number)[] = [];
		for (let x of [1, 2]) {
			fs.push(() => x);
			x += 1;
		}
		[3, 4].forEach((y) => {
			fs.push(() => y);
			y += 1;
		});
		console.log(fs.length);
	`,
	)
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, number_boxes(result, init) == 2, "%s", result.text)
}

@(test)
a_callback_through_a_closure_gets_only_what_it_takes :: proc(t: ^testing.T) {
	// `narrow` flows into a type that takes a label as well, so its class does; map passes the
	// element and pads the label with the empty string rather than handing it the index.
	result := lower_text(
		t,
		`
		function run(f: (x: number) => number): number[] {
			return [1, 2].map(f);
		}
		const narrow = (x: number): number => x * 2;
		const joined: (x: number, label: string) => number = narrow;
		console.log(run(narrow), joined(1, "a"));
	`,
	)
	run, _ := func_named(result.output, "m1.run")
	calls := instructions_of(run, ir.Call_Closure)
	if !testing.expectf(t, len(calls) == 1 && len(calls[0].args) == 2, "%s", result.text) {
		return
	}
	_, padded := run.values[calls[0].args[1]].variant.(ir.Const_String)
	testing.expectf(t, padded, "the second argument is not the class zero:\n%s", result.text)
	narrow, _ := func_prefixed(result.output, "m1.narrow$")
	testing.expect(t, slice.equal(narrow.params, []ir.Type{ir.F64, ir.STR}))
}

@(test)
sorting_with_a_comparator_passes_the_closure_as_it_stands :: proc(t: ^testing.T) {
	result := lower_text(t, "const xs = [2, 1];\nconsole.log(xs.sort((a, b) => a - b));\n")
	init, _ := func_named(result.output, "init$m1")
	testing.expectf(t, calls_to(init, .Array_Sort) == 1, "%s", result.text)
	_, adapted := func_prefixed(result.output, "m1.sort$")
	testing.expectf(t, !adapted, "an adapter for a comparator that needs none:\n%s", result.text)
}

@(test)
a_comparator_of_a_wider_class_goes_through_an_adapter :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		const byLength = (a: string, b: string): number => a.length - b.length;
		const loose: (a: string, b: string, c?: number) => number = byLength;
		console.log(["bb", "a"].sort(byLength), ["c"].sort(byLength), loose("a", "b"));
	`,
	)
	adapter, found := func_prefixed(result.output, "m1.sort$")
	if !testing.expectf(t, found, "%s", result.text) {
		return
	}
	testing.expect(t, slice.equal(adapter.params, []ir.Type{ir.STR, ir.STR}))
	testing.expect(t, adapter.result == ir.F64 && adapter.env != ir.NO_LAYOUT)
	adapters := 0
	for body in result.output.funcs {
		adapters += 1 if strings.has_prefix(body.name, "m1.sort$") else 0
	}
	testing.expectf(t, adapters == 1, "one adapter serves both calls:\n%s", result.text)
	calls := instructions_of(adapter, ir.Call_Closure)
	testing.expect(t, len(calls) == 1 && len(calls[0].args) == 3)
}

@(test)
a_widened_parameter_is_unboxed_with_a_check_on_the_way_in :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function show(x: number | string): void {
			console.log(x);
		}
		const square = (x: number): void => console.log(x * x);
		let printer: (x: number) => void = square;
		printer = show;
		printer(2);
	`,
	)
	square, found := func_prefixed(result.output, "m1.square$")
	if !testing.expectf(t, found, "%s", result.text) {
		return
	}
	testing.expect(t, slice.equal(square.params, []ir.Type{ir.TAGGED}))
	testing.expectf(t, len(instructions_of(square, ir.Tag_Test)) == 1, "%s", result.text)
	fails := instructions_of(square, ir.Fail)
	if testing.expectf(t, len(fails) == 1, "%s", result.text) {
		error := result.output.fail_sites[fails[0].site].error
		testing.expect_value(t, error, abi.Runtime_Error.Value_Of_Other_Kind)
	}
}

@(test)
a_void_result_takes_the_result_of_its_class :: proc(t: ^testing.T) {
	// `() => void` is one type wherever it is written, and `five` flows into it.
	result := lower_text(
		t,
		`
		const five = (): number => 5;
		const ignore: () => void = five;
		const quiet = (): void => {};
		console.log(ignore(), quiet());
	`,
	)
	quiet, found := func_prefixed(result.output, "m1.quiet$")
	five, _ := func_prefixed(result.output, "m1.five$")
	if !testing.expectf(t, found, "%s", result.text) {
		return
	}
	testing.expect(t, quiet.result == ir.F64 && five.result == ir.F64)
	returns := instructions_of(quiet, ir.Return)
	if testing.expectf(t, len(returns) == 1, "%s", result.text) {
		zero, is_number := number_at(quiet, returns[0].value)
		testing.expectf(t, is_number && zero == 0, "%s", result.text)
	}
}

@(test)
calling_a_value_of_type_any_is_reported :: proc(t: ^testing.T) {
	result := expect_later(
		t,
		"function call(f: any): void {\nf();\n}\ncall(1);\n",
		{{.Not_Lowered, 2, 1}},
	)
	testing.expect(t, slice.equal(result.constructs, []string{"calling a value of type any"}))
}

@(test)
a_function_with_a_rest_parameter_is_reported :: proc(t: ^testing.T) {
	result := expect_later(
		t,
		"function sum(...xs: number[]): number {\nreturn xs.length;\n}\nconsole.log(sum(1));\n",
		{{.Not_Lowered, 1, 10}},
	)
	testing.expect(t, slice.equal(result.constructs, []string{"rest parameters"}))
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
