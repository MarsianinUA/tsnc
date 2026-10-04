package opt_tests

import "core:testing"

import "../../src/ir"
import "../harness"

// tests/diff/src/stack-cells.ts runs the same shapes while the collector runs.

@(test)
a_cell_no_reference_leaves_goes_on_the_stack :: proc(t: ^testing.T) {
	// A loop keeps norm and size calls, and a write after a read keeps box a cell rather than its
	// fields. A union of objects takes the literal as it is, so drawn has nothing to box.
	result := optimize_text(
		t,
		`
		interface Point {
			x: number;
			y: number;
		}
		function norm(p: Point): number {
			let sum = 0;
			for (let i = 0; i < 2; i++) {
				sum += p.x * p.y;
			}
			return sum;
		}
		function area(w: number, h: number): number {
			const box = { w: w, h: h };
			box.w = box.w + 1;
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
		function same(p: Point): Point {
			return p;
		}
		function inlined(): number {
			const p = { x: 3, y: 4 };
			p.x = p.y + 1;
			return same(p).x;
		}
		interface Disc { kind: "disc"; r: number; }
		interface Ring { kind: "ring"; r: number; w: number; }
		function size(s: Disc | Ring): number {
			let sum = 0;
			for (let i = 0; i < 2; i++) {
				sum += s.r;
			}
			return sum;
		}
		function drawn(): number {
			return size({ kind: "disc", r: 2 });
		}
		console.log(area(2, 3), passed(), walked(), inlined(), drawn());
	`,
	)
	for name in ([?]string{"m1.area", "m1.passed", "m1.walked", "m1.inlined", "m1.drawn"}) {
		body := harness.func_named(t, result.output, name)
		places := cell_places(body)
		testing.expectf(t, places == {.Stack}, "%s: %v\n%s", name, places, result.after)
	}
}

@(test)
the_closure_of_a_loop_and_its_environment_go_on_the_stack :: proc(t: ^testing.T) {
	// The box of i is made again for every pass and reaches the next one through a phi, so it
	// stays on the heap. apply only calls its argument, and its loop keeps it a call.
	result := optimize_text(
		t,
		`
		function apply(f: (y: number) => number, y: number): number {
			let out = y;
			for (let k = 0; k < 2; k++) {
				out = f(out);
			}
			return out;
		}
		function made(n: number): number {
			let sum = 0;
			for (let i = 0; i < n; i++) {
				const add = (y: number) => y + i;
				sum += apply(add, i % 10);
			}
			return sum;
		}
		console.log(made(20));
	`,
	)
	made := harness.func_named(t, result.output, "m1.made")
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
		body := harness.func_named(t, result.output, name)
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
	handed := harness.func_named(t, result.output, "m1.handed")
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
	nest := harness.func_named(t, result.output, "m1.nest")
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
	for block in body.blocks {
		for value in block.instructions {
			if place := ir.cell_place(&body.values[value].variant); place != nil {
				places += {place^}
			}
		}
	}
	return
}
