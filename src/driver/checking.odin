#+private
/*
The unit of work of the type checker: one partition of the program, typed in one place.

run_check_task reads the frozen program, writes only into its own task, and touches neither the file
system nor anything another task owns, so running several of them at once changes nothing about the
result.

Partitions: contiguous File_ID ranges of about equal AST nodes, one per thread and at most one per
file. More partitions cost duplicated work: a checker types again what its files need from others.
The lib module is File_ID zero and is deliberately left out: it is read rather than typed, because
its declarations are the vocabulary every other file is measured against and nothing in it is a
mistake to report. tests/check/lib_test.odin is what pins that the lib itself types with no
diagnostic at all.
*/
package driver

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:thread"

import "../check"
import "../diag"
import "../program"
import "../source"

Check_Task :: struct {
	arena:       virtual.Arena, // holds the type table, the Typed_Files and the diagnostics
	prog:        ^program.Program,
	partition:   []source.File_ID,
	result:      check.Check_Result,
	diagnostics: []diag.Diagnostic,
}

// Measured over the test corpora: a checker takes about 5 KB, plus 94 bytes per node at the median
// and 353 at most (partitions of 100 nodes or more).
CHECK_ARENA_PER_NODE :: 384
CHECK_ARENA_MINIMUM :: 64 * mem.Kilobyte

// run_check_task leaves a result that borrows the names and the texts of the trees, so it lives
// exactly as long as the rest of the build.
run_check_task :: proc(task: ^Check_Task) {
	allocator := virtual.arena_allocator(&task.arena)
	task.result, task.diagnostics = check.check(task.prog, task.partition, allocator)
}

// partitions leaves every later partition at least one file.
partitions :: proc(
	prog: ^program.Program,
	jobs: int,
	allocator: runtime.Allocator,
) -> [][]source.File_ID {
	sources := len(prog.files) - 1
	count := min(jobs, max(sources, 1))
	files := make([]source.File_ID, sources, allocator)
	total := 0
	for i in 0 ..< sources {
		files[i] = source.File_ID(i + 1)
		total += len(prog.trees[i + 1].nodes)
	}

	out := make([][]source.File_ID, count, allocator)
	start, seen := 0, 0
	for part in 0 ..< count - 1 {
		share := total * (part + 1) / count
		end := start + 1
		seen += len(prog.trees[files[start]].nodes)
		for end < sources - (count - 1 - part) && seen < share {
			seen += len(prog.trees[files[end]].nodes)
			end += 1
		}
		out[part] = files[start:end]
		start = end
	}
	out[count - 1] = files[start:]
	return out
}

// Every arena is ready before the first task starts, so a failure leaves nothing running.
run_checkers :: proc(
	c: ^Closure,
	prog: ^program.Program,
	pool: ^thread.Pool,
	jobs: int,
) -> (
	results: []check.Check_Result,
	err: runtime.Allocator_Error,
) {
	ranges := partitions(prog, jobs, c.arena)
	for partition in ranges {
		nodes := 0
		for file in partition {
			nodes += len(prog.trees[file].nodes)
		}
		task := new(Check_Task, c.memory.allocator) or_return
		append(&c.memory.checks, task)
		task.prog = prog
		task.partition = partition
		reserved := max(uint(nodes) * CHECK_ARENA_PER_NODE, CHECK_ARENA_MINIMUM)
		virtual.arena_init_growing(&task.arena, reserved) or_return
	}

	fork_join(pool, c.memory.checks[:], run_check_task)

	results = make([]check.Check_Result, len(c.memory.checks), c.arena)
	for task, i in c.memory.checks {
		results[i] = task.result
		append(&c.diagnostics, ..task.diagnostics)
	}
	return results, nil
}
