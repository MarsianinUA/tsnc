package driver_tests

import "core:slice"
import "core:testing"

import "../../src/check"
import "../../src/driver"
import "../../src/source"

@(test)
errors_of_every_file_come_out_in_file_id_order :: proc(t: ^testing.T) {
	c := check_project("multi", "main.ts")
	defer driver.destroy(&c.report)

	// One pass reports every file's errors, sorted by (File_ID, offset, code): main.ts is 1
	// because it is the entry, then a.ts and b.ts in the order main.ts imports them. main.ts
	// spells one import `./a` and the other `./b.ts`, and both resolve.
	testing.expect_value(t, c.err.kind, driver.Error_Kind.None)
	testing.expectf(
		t,
		slice.equal(
			c.errors,
			[]Error {
				{"main.ts", .Expected_Token, 3, 9},
				{"a.ts", .Expected_Token, 1, 26},
				{"b.ts", .Var_Declaration, 1, 1},
			},
		),
		"errors %v",
		c.errors,
	)
}

@(test)
the_lib_is_module_zero :: proc(t: ^testing.T) {
	c := check_project("clean", "main.ts")
	defer driver.destroy(&c.report)

	// The lib goes in before anything the entry file could import, and it parses and binds like
	// any other file, so a mistake in it would show up here as a diagnostic against lib.d.ts.
	testing.expect_value(t, c.report.program.files[0].path, driver.LIB_PATH)
	testing.expect_value(t, string(c.report.program.files[0].text), driver.LIB_TEXT)
	testing.expect(t, len(c.report.program.trees[0].nodes) > 1)
	expect_clean(t, c)
}

@(test)
a_clean_program_reports_nothing :: proc(t: ^testing.T) {
	c := check_project("clean", "main.ts")
	defer driver.destroy(&c.report)

	expect_clean(t, c)
	testing.expect_value(
		t,
		slice.equal(file_names(c), []string{"lib.d.ts", "main.ts", "util.ts"}),
		true,
	)
	// Every file gets a row in each table of the program, all indexed by File_ID.
	program := c.report.program
	testing.expect_value(t, len(program.trees), len(program.files))
	testing.expect_value(t, len(program.bound), len(program.files))
	testing.expect_value(t, len(program.imports), len(program.files))
	testing.expect_value(t, len(program.init_order), len(program.files))
}

@(test)
two_runs_of_one_project_agree :: proc(t: ^testing.T) {
	first := check_project("multi", "main.ts")
	defer driver.destroy(&first.report)
	first_names := slice.clone(file_names(first), context.temp_allocator)
	first_errors := slice.clone(first.errors, context.temp_allocator)

	second := check_project("multi", "main.ts")
	defer driver.destroy(&second.report)

	// The guard T6.1 widens to `-j:1` against `-j:8`. Today it catches the file system: the walk
	// must not depend on the order a directory happens to hand its entries back in.
	testing.expect_value(t, slice.equal(first_names, file_names(second)), true)
	testing.expect_value(t, slice.equal(first_errors, second.errors), true)
}

@(test)
the_types_of_every_file_are_checked :: proc(t: ^testing.T) {
	c := check_project("types", "main.ts")
	defer driver.destroy(&c.report)

	// The checker runs over the whole program, not over the entry file alone, and its diagnostics
	// join the rest before the sort: the two from main.ts come before the one from util.ts, and a
	// type error sits next to a name error by position.
	testing.expect_value(t, c.err.kind, driver.Error_Kind.None)
	testing.expectf(
		t,
		slice.equal(
			c.errors,
			[]Error {
				{"main.ts", .Type_Mismatch, 3, 22},
				{"main.ts", .Cannot_Find_Name, 5, 27},
				{"util.ts", .Type_Mismatch, 5, 23},
			},
		),
		"errors %v",
		c.errors,
	)
}

@(test)
one_partition_holds_every_file_but_the_lib :: proc(t: ^testing.T) {
	c := check_project("clean", "main.ts")
	defer driver.destroy(&c.report)

	// v1 types the program in one call. The lib is module zero and is read rather than typed: its
	// declarations are what every other file is measured against, and tests/check/lib_test.odin is
	// what pins that the file itself has nothing wrong with it.
	testing.expect_value(t, len(c.report.results), 1)
	result := c.report.results[0]
	testing.expectf(
		t,
		slice.equal(result.partition, []source.File_ID{1, 2}),
		"partition %v",
		result.partition,
	)

	// A Typed_File for each, with a row for every node of its tree, which is what lower indexes.
	for file in result.partition {
		typed, ok := check.typed_file(result, file)
		testing.expectf(t, ok, "no Typed_File for %v", file)
		if !ok {
			continue
		}
		nodes := len(c.report.program.trees[file].nodes)
		testing.expect_value(t, len(typed.node_types), nodes)
		testing.expect_value(t, len(typed.node_symbols), nodes)
		testing.expect_value(t, len(typed.node_signatures), nodes)
	}
}

@(test)
only_a_program_without_errors_reaches_lower :: proc(t: ^testing.T) {
	clean := check_project("clean", "main.ts")
	defer driver.destroy(&clean.report)
	testing.expect_value(t, driver.has_errors(clean.report), false)

	typed := check_project("types", "main.ts")
	defer driver.destroy(&typed.report)
	testing.expect_value(t, driver.has_errors(typed.report), true)
}
