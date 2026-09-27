package check_tests

import "core:testing"

import "../../src/check"
import "../../src/source"

@(test)
the_well_known_types_are_where_the_constants_say :: proc(t: ^testing.T) {
	c := expect_checked(t, `const n = 1;`)

	testing.expect_value(t, check.ERROR, check.Type_ID(0))
	testing.expect_value(t, len(c.result.partition), 1)
	testing.expect_value(t, c.result.partition[0], MAIN)

	_, typed := check.typed_file(c.result, LIB)
	testing.expectf(t, !typed, "the lib file is not in this partition, so it has no Typed_File")
}

@(test)
a_checker_reports_only_the_files_of_its_partition :: proc(t: ^testing.T) {
	// Every file belongs to exactly one partition, so a mistake in a file this call does not type
	// belongs to the checker that does. That is what makes one partition and any other split give
	// the same diagnostics, which T6.2 compares byte for byte.
	sources := [2]string {
		`const good = 1;`, //
		`const bad: number = "a";`,
	}
	first := [1]source.File_ID{MAIN}
	second := [1]source.File_ID{MAIN + 1}

	one := check_sources(t, sources[:], first[:])
	testing.expectf(t, len(one.errors) == 0, "another file's mistake leaked in: %v", one.errors)

	two := check_sources(t, sources[:], second[:])
	testing.expect_value(t, len(two.errors), 1)
}
