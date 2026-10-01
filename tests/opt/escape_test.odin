package opt_tests

import "core:testing"

import "../../src/ir"

// Escape analysis: which cells go on the stack of their function. tests/diff/src/stack-cells.ts
// runs the same shapes while the collector runs.

@(test)
a_cell_no_reference_leaves_goes_on_the_stack :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		interface Point {
			x: number;
			y: number;
		}
		function norm(p: Point): number {
			return p.x * p.x + p.y * p.y;
		}
		function area(w: number, h: number): number {
			const box = { w: w, h: h };
			return box.w * box.h;
		}
		function passed(): number {
			const p = { x: 3, y: 4 };
			return norm(p);
		}
		function walked(): number {
			let sum = 0;
			for (const v of [1, 2, 3]) {
				sum += v;
			}
			return sum;
		}
		console.log(area(2, 3), passed(), walked());
	`,
	)
	for name in ([?]string{"m1.area", "m1.passed", "m1.walked"}) {
		body := func_named(result.output, name)
		places := cell_places(body)
		testing.expectf(t, places == {.Stack}, "%s: %v\n%s", name, places, result.after)
	}
}

@(test)
the_closure_of_a_loop_and_its_environment_go_on_the_stack :: proc(t: ^testing.T) {
	// The box of i is made again for every pass and reaches the next one through a phi, so it
	// stays on the heap.
	result := optimize_text(
		t,
		`
		function made(n: number): number {
			let sum = 0;
			for (let i = 0; i < n; i++) {
				const add = (y: number) => y + i;
				sum += add(i % 10);
			}
			return sum;
		}
		console.log(made(20));
	`,
	)
	made := func_named(result.output, "m1.made")
	_, closures := instructions_of(made, ir.Make_Closure)
	if !testing.expectf(t, len(closures) == 1, "%s", result.after) {
		return
	}
	env := made.values[closures[0].env].variant.(ir.Alloc)
	testing.expectf(t, closures[0].place == .Stack && env.place == .Stack, "%s", result.after)
	testing.expectf(t, .Heap in cell_places(made), "no box stayed:\n%s", result.after)
}

@(test)
a_cell_a_reference_to_which_may_leave_stays_on_the_heap :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		interface Point {
			x: number;
			y: number;
		}
		let kept: Point | null = null;
		function made(): Point {
			return { x: 1, y: 2 };
		}
		function stored(): void {
			kept = { x: 1, y: 2 };
		}
		function pushed(out: Point[]): void {
			out.push({ x: 1, y: 2 });
		}
		function logged(): void {
			const p = { x: 1, y: 2 };
			console.log(p);
		}
		function save(p: Point): void {
			kept = p;
		}
		function saved(): void {
			const p = { x: 1, y: 2 };
			save(p);
		}
		const out: Point[] = [];
		pushed(out);
		stored();
		logged();
		saved();
		console.log(made(), kept, out);
	`,
	)
	for name in ([?]string{"m1.made", "m1.stored", "m1.pushed", "m1.logged", "m1.saved"}) {
		body := func_named(result.output, name)
		places := cell_places(body)
		testing.expectf(t, places == {.Heap}, "%s: %v\n%s", name, places, result.after)
	}
}

@(test)
a_cell_a_closure_hands_back_out_of_its_environment_stays_on_the_heap :: proc(t: ^testing.T) {
	// The closure only reads its environment, but what it reads out of it leaves with its result.
	result := optimize_text(
		t,
		`
		interface Point {
			x: number;
			y: number;
		}
		function handed(): Point {
			const p = { x: 1, y: 2 };
			const get = () => p;
			return get();
		}
		console.log(handed());
	`,
	)
	handed := func_named(result.output, "m1.handed")
	_, allocs := instructions_of(handed, ir.Alloc)
	testing.expectf(t, len(allocs) == 2, "%s", result.after)
	for alloc in allocs {
		testing.expectf(t, alloc.place == .Heap, "%v:\n%s", alloc, result.after)
	}
}

@(test)
a_cell_of_an_inner_loop_stored_into_one_of_an_outer_loop_stays_on_the_heap :: proc(t: ^testing.T) {
	// The inner cell is made again on every pass of the inner loop while the outer one still points
	// to the last one.
	result := optimize_text(
		t,
		`
		interface Point {
			x: number;
			y: number;
		}
		interface Holder {
			item: Point | null;
		}
		function nest(): number {
			let total = 0;
			for (let i = 0; i < 3; i++) {
				const holder: Holder = { item: null };
				for (let j = 0; j < 3; j++) {
					holder.item = { x: i, y: j };
				}
				const last = holder.item;
				if (last !== null) {
					total += last.x + last.y;
				}
			}
			return total;
		}
		console.log(nest());
	`,
	)
	nest := func_named(result.output, "m1.nest")
	_, allocs := instructions_of(nest, ir.Alloc)
	testing.expectf(t, len(allocs) == 2, "%s", result.after)
	for alloc in allocs {
		holder := result.output.layouts[alloc.layout].fields[0].name == "item"
		want := ir.Cell_Place.Stack if holder else .Heap
		testing.expectf(t, alloc.place == want, "%v:\n%s", alloc, result.after)
	}
}

@(private = "file")
cell_places :: proc(body: ir.Func) -> (places: bit_set[ir.Cell_Place]) {
	for instruction in body.values {
		#partial switch v in instruction.variant {
		case ir.Alloc:
			places += {v.place}
		case ir.New_Array:
			places += {v.place}
		case ir.Make_Closure:
			places += {v.place}
		}
	}
	return
}
