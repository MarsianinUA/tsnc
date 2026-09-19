package driver_tests

import "core:slice"
import "core:testing"

import "../../src/driver"

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
	testing.expect_value(t, c.report.files[0].path, driver.LIB_PATH)
	testing.expect_value(t, string(c.report.files[0].text), driver.LIB_TEXT)
	testing.expect(t, len(c.report.trees[0].nodes) > 1)
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
	// Every file gets a row in each table, so T3.1 can index them all by File_ID.
	testing.expect_value(t, len(c.report.trees), len(c.report.files))
	testing.expect_value(t, len(c.report.bound), len(c.report.files))
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
