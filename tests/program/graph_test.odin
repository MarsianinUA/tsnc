package program_tests

import "core:slice"
import "core:testing"

import "../../src/diag"

@(test)
a_chain_initializes_from_the_far_end :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2}},
			{path = "a.ts", imports = {3}},
			{path = "b.ts"},
		},
	)

	// main imports a and a imports b, so b has to run first: a module only runs once everything it
	// imports has run.
	testing.expect_value(
		t,
		slice.equal(order_names(b), []string{"lib.d.ts", "b.ts", "a.ts", "main.ts"}),
		true,
	)
	expect_no_cycles(t, b)
}

@(test)
a_diamond_initializes_the_shared_module_once :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2, 3}},
			{path = "a.ts", imports = {4}},
			{path = "b.ts", imports = {4}},
			{path = "c.ts"},
		},
	)

	// a and b both import c. c runs first and once, then the two that share it, then main.
	testing.expect_value(
		t,
		slice.equal(order_names(b), []string{"lib.d.ts", "c.ts", "a.ts", "b.ts", "main.ts"}),
		true,
	)
	expect_no_cycles(t, b)
}

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
a_cycle_of_types_and_functions_is_allowed :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2}},
			{path = "a.ts", imports = {3}},
			{path = "b.ts", imports = {2}},
		},
	)

	// a and b import each other, and neither runs anything as it loads, so neither can read a
	// value the other has not produced yet (requirements 7).
	testing.expect_value(t, len(b.program.cycles), 1)
	testing.expect_value(t, slice.equal(cycle_names(b, 0), []string{"a.ts", "b.ts"}), true)
	testing.expect_value(t, b.program.cycles[0].has_effects, false)
	testing.expect_value(t, len(b.diagnostics), 0)
}

@(test)
a_cycle_with_side_effects_is_reported_at_the_import_that_closes_it :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2}},
			{path = "a.ts", imports = {3}, effects = true},
			{path = "b.ts", imports = {2}},
		},
	)

	testing.expect_value(t, len(b.program.cycles), 1)
	testing.expect_value(t, b.program.cycles[0].has_effects, true)
	testing.expect_value(t, len(b.diagnostics), 1)
	if len(b.diagnostics) != 1 {
		return
	}

	// The message stands on a.ts's import of b.ts, the first request of the ring's first module
	// that points back into the ring, and names every module of the ring.
	d := b.diagnostics[0]
	testing.expect_value(t, d.code, diag.Code.Cycle_With_Side_Effects)
	testing.expect_value(t, d.span, request_span(2, 0))
	testing.expect_value(t, d.args[0], "`a.ts`, `b.ts`")
}

@(test)
one_ring_of_three_modules_is_one_message :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2}},
			{path = "a.ts", imports = {3}},
			{path = "b.ts", imports = {4}},
			{path = "c.ts", imports = {2}, effects = true},
		},
	)

	// One ring is one mistake, wherever in it the code that runs happens to sit.
	testing.expect_value(t, len(b.program.cycles), 1)
	testing.expect_value(t, slice.equal(cycle_names(b, 0), []string{"a.ts", "b.ts", "c.ts"}), true)
	testing.expect_value(t, len(b.diagnostics), 1)
	testing.expect_value(t, b.diagnostics[0].args[0], "`a.ts`, `b.ts`, `c.ts`")
}

@(test)
a_type_only_import_orders_nothing :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2}},
			{path = "a.ts", type_imports = {3}, effects = true},
			{path = "b.ts", imports = {2}, effects = true},
		},
	)

	// b imports a for a value, but a only imports b's types, and Node never loads a module
	// imported that way. There is no ring to run in the wrong order, so there is nothing to
	// report, even though both modules run code as they load.
	expect_no_cycles(t, b)
	testing.expect_value(
		t,
		slice.equal(order_names(b), []string{"lib.d.ts", "a.ts", "main.ts", "b.ts"}),
		true,
	)
}

@(test)
a_module_that_imports_itself_is_not_a_cycle :: proc(t: ^testing.T) {
	b := build_graph(
		{
			{path = "lib.d.ts"},
			{path = "main.ts", imports = {2}},
			{path = "a.ts", imports = {2}, effects = true},
		},
	)

	// A module always sees itself, so importing itself orders nothing and waits for nothing.
	expect_no_cycles(t, b)
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
