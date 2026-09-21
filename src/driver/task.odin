#+private
/*
The unit of work of the frontend: one file, parsed and bound in one place.

run_file_task is the shape T6.1 hands to core:thread.Pool. It reads no shared state, writes only
into its own task, and never touches the file system, so running many of them at once changes
nothing about the result. Reading the file stays in the closure loop, where the imperative code
belongs.
*/
package driver

import "core:mem/virtual"

import "../ast"
import "../bind"
import "../diag"
import "../parse"
import "../source"

// File_Task is always heap-allocated: the allocator taken from arena below captures it by pointer,
// so the task must never move.
File_Task :: struct {
	arena:       virtual.Arena, // holds tree, bound and diagnostics until the end of the build
	file:        source.File_ID,
	text:        string, // borrowed from the driver arena
	tree:        ast.File_AST,
	bound:       bind.Bound_File,
	diagnostics: []diag.Diagnostic, // parse's first, then bind's
}

// run_file_task hands bind the tree stored in the task, not a copy, because Bound_File borrows from
// it.
run_file_task :: proc(task: ^File_Task) {
	allocator := virtual.arena_allocator(&task.arena)

	parse_diagnostics: []diag.Diagnostic
	task.tree, parse_diagnostics = parse.parse_file(task.text, task.file, allocator)

	bind_diagnostics: []diag.Diagnostic
	task.bound, bind_diagnostics = bind.bind_file(&task.tree, allocator)

	// One slice in a fixed order, so the merged list of a build does not depend on how the phases
	// are scheduled. diag.sort is stable and puts them in print order later.
	merged := make([]diag.Diagnostic, len(parse_diagnostics) + len(bind_diagnostics), allocator)
	copy(merged[:len(parse_diagnostics)], parse_diagnostics)
	copy(merged[len(parse_diagnostics):], bind_diagnostics)
	task.diagnostics = merged
}
