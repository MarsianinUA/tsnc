#+private
/*
The unit of work of the frontend: one file, parsed and bound in one place.

run_file_task reads no shared state, writes only into its own task, and never touches the file
system, so running many of them at once changes nothing about the result. Reading the file stays
in the closure loop, where the imperative code belongs.
*/
package driver

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:thread"

import "../ast"
import "../bind"
import "../diag"
import "../parse"
import "../source"

File_Task :: struct {
	arena:       virtual.Arena, // holds tree, bound and diagnostics until the end of the build
	file:        source.File_ID,
	text:        string, // borrowed from the driver arena
	tree:        ast.File_AST,
	bound:       bind.Bound_File,
	diagnostics: []diag.Diagnostic, // parse's first, then bind's
}

// An arena reserves address space for its file and commits pages as parse and bind use them. A
// zeroed arena would commit a whole 1 MiB block on its first allocation instead, 1 GiB for a
// thousand files. Measured over the test corpora: parse and bind take 23 bytes per byte of source
// at the median and 62 at most, and the 79 files of tests/diff commit 7 MB where zeroed arenas
// committed 83 MB. Reserving too little costs one more block, never a failure.
TASK_ARENA_PER_SOURCE_BYTE :: 64
TASK_ARENA_MINIMUM :: 64 * mem.Kilobyte

// parse_wave runs one round of the closure loop: the files known when it started. It sizes every
// arena before it adds a task, so a failure leaves nothing running.
parse_wave :: proc(pool: ^thread.Pool, tasks: []^File_Task) -> runtime.Allocator_Error {
	for task in tasks {
		reserved := max(uint(len(task.text)) * TASK_ARENA_PER_SOURCE_BYTE, TASK_ARENA_MINIMUM)
		virtual.arena_init_growing(&task.arena, reserved) or_return
	}
	fork_join(pool, tasks, run_file_task)
	return nil
}

// run_file_task hands bind the tree stored in the task, not a copy, because Bound_File borrows from
// it.
run_file_task :: proc(task: ^File_Task) {
	allocator := virtual.arena_allocator(&task.arena)

	parse_diagnostics: []diag.Diagnostic
	task.tree, parse_diagnostics = parse.parse_file(task.text, task.file, allocator)

	bind_diagnostics: []diag.Diagnostic
	task.bound, bind_diagnostics = bind.bind_file(&task.tree, allocator)

	merged := make([]diag.Diagnostic, len(parse_diagnostics) + len(bind_diagnostics), allocator)
	copy(merged[:len(parse_diagnostics)], parse_diagnostics)
	copy(merged[len(parse_diagnostics):], bind_diagnostics)
	task.diagnostics = merged
}

// fork_join runs work on every task in the pool, with the task's arena as its allocator, and
// returns when all are done. A worker rewinds its scratch after each task, or it would hold the
// scratch of every task it ran.
fork_join :: proc(pool: ^thread.Pool, tasks: []^$T, work: proc(task: ^T)) {
	Join :: struct {
		tasks: []^T,
		work:  proc(task: ^T),
		done:  sync.Wait_Group,
	}
	join := Join {
		tasks = tasks,
		work  = work,
	}
	run :: proc(task: thread.Task) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		join := (^Join)(task.data)
		join.work(join.tasks[task.user_index])
		sync.wait_group_done(&join.done)
	}
	sync.wait_group_add(&join.done, len(tasks))
	for task, i in tasks {
		thread.pool_add_task(pool, virtual.arena_allocator(&task.arena), run, &join, i)
	}
	sync.wait_group_wait(&join.done)
}
