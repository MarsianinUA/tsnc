package check_tests

import "core:testing"

import "../../src/source"

@(test)
the_lib_file_types_without_a_diagnostic :: proc(t: ^testing.T) {
	// lib.d.ts is File_ID zero of every program, and it is written almost entirely out of
	// constructs later tasks of this milestone own: interfaces, generic interfaces, array types and
	// named types. This is the guard that they stay silent, so that a checker over a partition that
	// holds the lib file does not bury the user under messages about work that is not done yet.
	partition := [1]source.File_ID{LIB}
	c := check_sources(t, nil, partition[:])

	testing.expectf(t, len(c.errors) == 0, "lib.d.ts: %v", c.errors)
}
