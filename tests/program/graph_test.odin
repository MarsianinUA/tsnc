package program_tests

import "core:slice"
import "core:testing"

@(test)
every_module_takes_one_place_in_the_order :: proc(t: ^testing.T) {
	// c imports a back, so a, b and c share one place in the order.
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2, 3}},
			{path = "a.ts", imports = {3, 4}},
			{path = "b.ts", imports = {4}},
			{path = "c.ts", imports = {2}},
		},
	)

	// Whatever the shape, the order is a permutation of the File_ID values: lower reads it to emit
	// one init function per module, so a module missing from it or listed twice would be a bug.
	seen := make([]bool, len(b.program.files), context.temp_allocator)
	for module in b.program.init_order {
		testing.expectf(t, !seen[module], "module %v is in the order twice", module)
		seen[module] = true
	}
	testing.expect_value(t, len(b.program.init_order), len(b.program.files))
}

@(test)
two_runs_of_one_graph_agree :: proc(t: ^testing.T) {
	modules := []Module {
		{path = "lib.d.ts"},
		{path = "main.ts", imports = {2, 3}},
		{path = "a.ts", imports = {4}},
		{path = "b.ts", imports = {4, 2}},
		{path = "c.ts", effects = true},
	}

	first := build_graph(modules)
	first_order := slice.clone(order_names(first), context.temp_allocator)
	second := build_graph(modules)

	// The order and the rings are read by lower and end up in the executable, so they must not
	// depend on a hash seed or on where a table happened to land in memory.
	testing.expect_value(t, slice.equal(first_order, order_names(second)), true)
	testing.expect_value(t, len(first.program.cycles), len(second.program.cycles))
	testing.expect_value(t, len(first.diagnostics), len(second.diagnostics))
}
