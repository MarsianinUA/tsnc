package check_tests

import "base:runtime"
import "core:fmt"
import "core:testing"

// Every program of the differential corpus builds, so check accepts each without a diagnostic, and
// check_sources runs check_typed over far more shapes than the tests beside this one feed it.
@(test)
every_program_of_the_diff_corpus_checks_without_a_diagnostic :: proc(t: ^testing.T) {
	programs := #load_directory("../diff/src")
	modules := #load_directory("../diff/src/modules")

	for program in programs {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		// A module the program does not import is one more root of the graph, typed like any other.
		count := len(modules) + 1
		sources := make([]string, count, context.temp_allocator)
		names := make([]string, count, context.temp_allocator)
		sources[0], names[0] = string(program.data), program.name
		for module, i in modules {
			sources[i + 1] = string(module.data)
			names[i + 1] = fmt.tprintf("modules/%s", module.name)
		}

		c := check_sources(t, sources, every_source(count), names)
		testing.expectf(t, len(c.file_errors) == 0, "%s: %v", program.name, c.file_errors)
	}
}
