package driver_tests

import "core:slice"
import "core:testing"

import "../../src/driver"

@(test)
file_ids_follow_breadth_first_source_order :: proc(t: ^testing.T) {
	c := check_project("diamond", "main.ts")
	defer driver.destroy(&c.report)

	expect_clean(t, c)
	// main imports a then b, and both import c. Breadth first numbers the two direct imports
	// before the one they share, whatever order the file system hands them back in.
	testing.expect_value(
		t,
		slice.equal(file_names(c), []string{"lib.d.ts", "main.ts", "a.ts", "b.ts", "c.ts"}),
		true,
	)
}

@(test)
a_cycle_is_read_once_and_terminates :: proc(t: ^testing.T) {
	c := check_project("cycle", "main.ts")
	defer driver.destroy(&c.report)

	// a imports b and b imports a. The walk ends because a file already numbered is never read
	// again; whether the cycle itself is allowed is a question for program in T3.1.
	expect_clean(t, c)
	testing.expect_value(
		t,
		slice.equal(file_names(c), []string{"lib.d.ts", "main.ts", "a.ts", "b.ts"}),
		true,
	)
}

@(test)
both_import_spellings_reach_one_file :: proc(t: ^testing.T) {
	c := check_project("spelling", "main.ts")
	defer driver.destroy(&c.report)

	// `./m` and `./m.ts` name the same file, so it is read once and gets one File_ID.
	expect_clean(t, c)
	testing.expect_value(
		t,
		slice.equal(file_names(c), []string{"lib.d.ts", "main.ts", "m.ts"}),
		true,
	)
}

@(test)
a_missing_module_is_reported_at_every_import :: proc(t: ^testing.T) {
	c := check_project("missing", "main.ts")
	defer driver.destroy(&c.report)

	// Two imports of one missing module are two mistakes in two places, so both are reported,
	// each at the specifier it stands on. The file itself is looked for only once.
	testing.expect_value(t, c.err.kind, driver.Error_Kind.None)
	testing.expectf(
		t,
		slice.equal(
			c.errors,
			[]Error{{"main.ts", .Module_Not_Found, 1, 19}, {"main.ts", .Module_Not_Found, 2, 19}},
		),
		"errors %v",
		c.errors,
	)
	testing.expect_value(t, len(c.report.files), 2) // the lib and main.ts, nothing else
}

@(test)
a_bare_specifier_is_reported_at_the_import :: proc(t: ^testing.T) {
	c := check_project("bare", "main.ts")
	defer driver.destroy(&c.report)

	// Nothing is looked for on disk: a package name never names a file (requirements 7 and 12).
	testing.expectf(
		t,
		slice.equal(c.errors, []Error{{"main.ts", .Bare_Specifier, 1, 26}}),
		"errors %v",
		c.errors,
	)
}

@(test)
a_missing_entry_file_is_a_driver_error :: proc(t: ^testing.T) {
	c := check_project("clean", "not-here.ts")
	defer driver.destroy(&c.report)

	// The entry file has no import to point at, so it cannot be a diagnostic.
	testing.expect_value(t, c.err.kind, driver.Error_Kind.Entry_Unreadable)
	testing.expect(t, len(c.err.detail) > 0)
	testing.expect_value(t, len(c.errors), 0)
}
