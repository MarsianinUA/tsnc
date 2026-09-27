package driver_tests

import "core:slice"
import "core:testing"

import "../../src/check"
import "../../src/driver"
import "../../src/source"

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
the_thread_count_changes_no_number_and_no_diagnostic :: proc(t: ^testing.T) {
	one := check_project("multi", "main.ts", jobs = 1)
	defer driver.destroy(&one.report)

	// Three waves: main, then big and the five small modules it imports, then what those import.
	// main imports big first, and at eight threads the small ones finish before it.
	names := []string {
		"lib.d.ts",
		"main.ts",
		"big.ts",
		"a.ts",
		"b.ts",
		"c.ts",
		"d.ts",
		"e.ts",
		"deep.ts",
		"shared.ts",
	}
	testing.expectf(t, slice.equal(file_names(one), names), "files %v", file_names(one))
	// Every file but the lib has one mistake, of parse, bind or check, so a changed order shows.
	testing.expectf(t, len(one.errors) == len(names) - 1, "errors %v", one.errors)

	// Several runs, because a race shows only in some of them.
	for _ in 0 ..< 10 {
		eight := check_project("multi", "main.ts", jobs = 8)
		defer driver.destroy(&eight.report)
		testing.expectf(t, slice.equal(file_names(eight), names), "files %v", file_names(eight))
		testing.expectf(t, slice.equal(eight.errors, one.errors), "errors %v", eight.errors)
	}
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
