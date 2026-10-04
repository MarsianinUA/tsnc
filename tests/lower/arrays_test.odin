package lower_tests

import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../harness"

// Arrays: the four loops lower builds around a callback.

@(test)
the_four_callback_methods_are_loops_with_the_callback_inlined :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function sum(xs: number[]): number {
			let total = 0;
			xs.forEach((x, i) => {
				if (i > 5) {
					return;
				}
				total += x;
			});
			const doubled = xs.map(x => x * 2);
			const big = xs.filter(x => {
				if (x > 2) {
					return true;
				}
				return false;
			});
			return total + doubled.length + big.length + xs.reduce((a, b) => a + b, 0);
		}
		console.log(sum([1, 2, 3]));
	`,
	)
	body := harness.func_named(t, result.output, "m1.sum")
	testing.expectf(t, len(instructions_of(body, ir.Call)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Call_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Make_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Func_Ref)) == 0, "%s", result.text)
}

@(test)
a_callback_may_be_the_name_of_a_function :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function double(x: number): number {
			return x * 2;
		}
		console.log([1, 2].map(double));
	`,
	)
	init := harness.func_named(t, result.output, "init$m1")
	testing.expectf(t, calls_function(result.output, init, "m1.double"), "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Func_Ref)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(init, ir.Call_Closure)) == 0, "%s", result.text)
}

// push and pop stay in generated code: the runtime only grows a full array, behind a Reserve.
@(test)
push_and_pop_call_no_runtime :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function cycle(xs: number[]): number | undefined {
			xs.push(1, 2);
			return xs.pop();
		}
		console.log(cycle([]));
	`,
	)
	body := harness.func_named(t, result.output, "m1.cycle")
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Reserve)) > 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Set_Length)) > 0, "%s", result.text)
}

// A flow of one array type into a wider one that is written through changes the slot of those two
// only: the class is keyed by the element below its slot, so the other arrays of references keep
// theirs.
@(test)
an_array_flow_widens_its_own_class_only :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Disc { r: number; }
		interface Square { side: number; }
		const discs: Disc[] = [{ r: 1 }];
		const shapes: (Disc | Square)[] = discs;
		shapes.push({ side: 3 });
		const squares: Square[] = [{ side: 2 }];
		const words: string[] = ["a"];
		const grid: number[][] = [[1]];
		console.log(shapes, squares, words, grid);
	`,
	)
	Slot :: struct {
		name: string,
		kind: abi.Slot_Kind,
	}
	want := [?]Slot {
		{"m1.discs", .Any_Ref},
		{"m1.squares", .Ref},
		{"m1.words", .Ref},
		{"m1.grid", .Ref},
	}
	for slot in want {
		global := harness.global_named(t, result.output, slot.name)
		element := result.output.layouts[global.type.layout].element
		testing.expectf(
			t,
			element == slot.kind,
			"%s holds %v: %s",
			slot.name,
			element,
			result.text,
		)
	}
}

// A flow into a wider array type that nothing writes through leaves the array that flows in as it
// is: sum reads f64 elements, and only describe, the wide side, has a pointer of several layouts.
@(test)
an_array_type_only_read_through_keeps_what_flows_in :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function sum(a: number[]): number {
			let s = 0;
			for (let i = 0; i < a.length; i++) s += a[i];
			return s;
		}
		function describe(items: (number | string)[]): number {
			return items.length;
		}
		const a: number[] = [];
		a.push(0.5);
		console.log(sum(a), describe(a));
	`,
	)
	sum := harness.func_named(t, result.output, "m1.sum")
	loads := 0
	for value in sum.values {
		if _, is_load := value.variant.(ir.Element_Load); is_load {
			loads += 1
			testing.expectf(t, value.type == ir.F64, "sum loads %v:\n%s", value.type, result.text)
		}
	}
	testing.expectf(t, loads > 0, "sum reads no element:\n%s", result.text)
	describe := harness.func_named(t, result.output, "m1.describe")
	testing.expectf(t, describe.params[0] == ir.ANY_REF, "%s", result.text)
}
