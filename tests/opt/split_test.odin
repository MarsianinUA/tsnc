package opt_tests

import "core:testing"

import "../../src/ir"
import "../harness"

// acc is a new cell on every pass, carried to the next one through a phi.
@(test)
a_cell_only_read_after_it_is_made_becomes_its_fields :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		interface Vec {
			x: number;
			y: number;
			z: number;
		}
		function add(a: Vec, b: Vec): Vec {
			return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
		}
		function scale(a: Vec, k: number): Vec {
			return { x: a.x * k, y: a.y * k, z: a.z * k };
		}
		function main(): void {
			let acc: Vec = { x: 0, y: 0, z: 0 };
			const step: Vec = { x: 1, y: 2, z: 3 };
			for (let i = 0; i < 10; i++) {
				acc = add(scale(acc, 0.5), step);
			}
			console.log(acc.x + acc.y + acc.z);
		}
		function moved(): number {
			const p: Vec = { x: 1, y: 2, z: 3 };
			p.x = p.y + 1;
			return p.x * p.z;
		}
		main();
		console.log(moved());
	`,
	)
	main := harness.func_named(t, result.output, "m1.main")
	_, allocs := placed_of(main, ir.Alloc)
	testing.expectf(t, len(allocs) == 0, "%s", result.after)
	ids, _ := placed_of(main, ir.Phi)
	fields := 0
	for id in ids {
		fields += 1 if main.values[id].type == ir.F64 else 0
	}
	testing.expectf(t, fields == 3, "%s", result.after)

	moved := harness.func_named(t, result.output, "m1.moved")
	_, allocs = placed_of(moved, ir.Alloc)
	testing.expectf(t, len(allocs) == 1, "a cell written after a read is gone:\n%s", result.after)
}
