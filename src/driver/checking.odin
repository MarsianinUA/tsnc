#+private
/*
The unit of work of the type checker: one partition of the program, typed in one place.

run_check_task reads the frozen program, writes only into its own task, and touches neither the file
system nor anything another task owns, so running several of them at once changes nothing about the
result.

Partitions. v1 makes one partition of every source file. The lib module is File_ID zero and is
deliberately left out: it is read rather than typed, because its declarations are the vocabulary
every other file is measured against and nothing in it is a mistake to report.
tests/check/lib_test.odin is what pins that the lib itself types with no diagnostic at all.
*/
package driver

import "base:runtime"
import "core:mem/virtual"

import "../check"
import "../diag"
import "../program"
import "../source"

Check_Task :: struct {
	arena:       virtual.Arena, // holds the type table, the Typed_Files and the diagnostics
	partition:   []source.File_ID,
	result:      check.Check_Result,
	diagnostics: []diag.Diagnostic,
}

// run_check_task leaves a result that borrows the names and the texts of the trees, so it lives
// exactly as long as the rest of the build.
run_check_task :: proc(task: ^Check_Task, prog: ^program.Program) {
	allocator := virtual.arena_allocator(&task.arena)
	task.result, task.diagnostics = check.check(prog, task.partition, allocator)
}

// source_partition is every file of the program but the lib, which is the whole of v1's split.
source_partition :: proc(count: int, allocator: runtime.Allocator) -> []source.File_ID {
	partition := make([]source.File_ID, max(count - 1, 0), allocator)
	for i in 0 ..< len(partition) {
		partition[i] = source.File_ID(i + 1)
	}
	return partition
}

run_checkers :: proc(c: ^Closure, prog: ^program.Program) -> []check.Check_Result {
	task := new(Check_Task, c.memory.allocator)
	task.partition = source_partition(len(c.files), c.arena)
	append(&c.memory.checks, task)

	run_check_task(task, prog)
	append(&c.diagnostics, ..task.diagnostics)

	results := make([]check.Check_Result, 1, c.arena)
	results[0] = task.result
	return results
}
