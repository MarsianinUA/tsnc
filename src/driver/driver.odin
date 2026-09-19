/*
Build orchestration. driver is the compiler's only imperative layer: it reads files, owns every
arena, walks the import graph and hands each file its File_ID. The phases it calls are pure, so
everything they need arrives as a value plus an allocator, and they hand back data plus
diagnostics.

check_only is the `tsnc check` stage: it builds the import closure from the entry file, parses and
binds every file in it, and returns one row per File_ID together with every diagnostic, already in
print order. driver never prints and never sets the exit code; main does both. build and run join
in T4.5, and T3.1 turns files, trees and bound into a program.Program.

File_ID order. The lib file is 0, the entry file is 1, and an imported file takes the next number
as the walk first reaches it. Files are processed in increasing File_ID and each file's requests in
source order, which is breadth-first traversal, so the numbering follows the source text and not
the file system. From T6.1 it will not follow the number of threads either.

Memory. One arena per file task, holding that file's tokens, AST and Bound_File, plus one driver
arena for the file table, the path strings, the file texts and the merged diagnostics. Everything
lives until destroy, because each layer borrows from the one under it: the AST points into the file
text and the Bound_File points into the AST. Nothing is freed one object at a time.

Errors. A file that cannot be read is an infrastructure failure, and it has two forms. The entry
file has no span to point at, so it comes back as a Driver_Error. Anything reached through an
import has one, the specifier, so it becomes a diagnostic like any other compile error and the
walk goes on to report the rest.
*/
package driver

import "base:runtime"
import "core:mem/virtual"

import "../ast"
import "../bind"
import "../codegen"
import "../diag"
import "../source"
import "../target"

// LIB_TEXT is the built-in lib.d.ts, module zero of every program. It goes through the same parse
// and bind as a user file.
LIB_TEXT :: #load("../lib/lib.d.ts", string)

// LIB_PATH is what a diagnostic in the lib file prints. The file is embedded, so no path on disk
// would lead a reader anywhere.
LIB_PATH :: "lib.d.ts"

// Command values are lowercase because core:flags matches them against the command line by exact
// name: `tsnc build`. codegen.Optimization and target.Target follow the same rule for `-o:` and
// `-target:`.
Command :: enum {
	build,
	run,
	check,
}

// Options is what main parses the command line into and the only thing driver takes from it.
Options :: struct {
	command:      Command `args:"pos=0,required" usage:"build, run or check"`,
	input:        string `args:"pos=1,required" usage:"entry .ts file"`,
	output:       string `args:"name=out" usage:"output path"`,
	optimization: codegen.Optimization `args:"name=o" usage:"optimization level (default: speed)"`,
	emit_llvm:    bool `usage:"write textual LLVM IR instead of an executable"`,
	emit_ir:      bool `usage:"write the tsnc IR dump instead of an executable"`,
	target:       target.Target `usage:"target platform, for example linux_amd64 (default: host)"`,
	jobs:         int `args:"name=j" usage:"worker threads (default: number of cores)"`,
}

Error_Kind :: enum u8 {
	None,
	Entry_Unreadable, // detail: the path, then why it could not be read
	Entry_Too_Large, // detail: the path
	Out_Of_Memory, // detail: empty
}

// Driver_Error is a failure that stops the build before it starts. A failure with a place in the
// source is a diag.Diagnostic instead.
Driver_Error :: struct {
	kind:   Error_Kind,
	detail: string, // owned by the report's memory; empty for None
}

// Check_Report is the frozen result of check_only, one row per File_ID with the lib at zero. The
// rows outlive nothing: destroy invalidates all of them at once.
Check_Report :: struct {
	files:       []source.File, // indexed by File_ID
	trees:       []ast.File_AST, // indexed by File_ID
	bound:       []bind.Bound_File, // indexed by File_ID
	diagnostics: []diag.Diagnostic, // every phase's and driver's own, in print order
	memory:      ^Build_Memory, // owns the arenas the rows live in
}

// Build_Memory holds every arena of one build. Only driver touches it; a caller passes it back to
// destroy. It is heap-allocated because an arena must not move: virtual.arena_allocator captures
// the arena by pointer, so a copied or reallocated arena leaves its allocator pointing at the old
// address.
Build_Memory :: struct {
	arena:     virtual.Arena, // the file table, the paths, the file texts, the merged diagnostics
	tasks:     [dynamic]^File_Task, // one per File_ID, each owning its own arena
	allocator: runtime.Allocator, // where the struct above came from, for destroy
}

// check_only reads the entry file, follows its imports, and parses and binds every file it finds.
// It reports every error it can rather than stopping at the first: a file that fails to parse
// still gets bound, and a module that cannot be found does not end the walk.
@(require_results)
check_only :: proc(
	options: Options,
	allocator := context.allocator,
) -> (
	report: Check_Report,
	err: Driver_Error,
) {
	memory := new(Build_Memory, allocator)
	memory.allocator = allocator
	if virtual.arena_init_growing(&memory.arena) != nil {
		free(memory, allocator)
		return {}, {kind = .Out_Of_Memory}
	}
	memory.tasks = make([dynamic]^File_Task, allocator)

	c := Closure {
		memory = memory,
		arena  = virtual.arena_allocator(&memory.arena),
	}
	c.files = make([dynamic]source.File, c.arena)
	c.absolute = make([dynamic]string, c.arena)
	c.diagnostics = make([dynamic]diag.Diagnostic, c.arena)
	c.by_key = make(map[string]source.File_ID, c.arena)
	c.failed = make(map[string]Failure, c.arena)

	// Module zero, before anything the entry file might import.
	add_file(&c, LIB_PATH, "", LIB_TEXT)

	// The memory goes back with the report even though there is nothing to report: err.detail
	// lives in that arena, so freeing it here would hand the caller a dangling string.
	if err = add_entry(&c, options.input); err.kind != .None {
		return {memory = memory}, err
	}

	// Growing c.files inside the loop is what makes this breadth-first: a file discovered now is
	// numbered after every file already known, and its own imports are followed later.
	for id := 0; id < len(c.files); id += 1 {
		task := c.memory.tasks[id]
		run_file_task(task)
		append(&c.diagnostics, ..task.diagnostics)
		follow_requests(&c, source.File_ID(id))
	}

	count := len(c.files)
	trees := make([]ast.File_AST, count, c.arena)
	bound := make([]bind.Bound_File, count, c.arena)
	for task, i in c.memory.tasks {
		trees[i] = task.tree
		bound[i] = task.bound
	}

	diagnostics := c.diagnostics[:]
	diag.sort(diagnostics)

	return {
		files = c.files[:],
		trees = trees,
		bound = bound,
		diagnostics = diagnostics,
		memory = memory,
	}, {}
}

// destroy releases every arena of the build. Nothing the report points at is valid afterwards,
// including the text of its diagnostics. Calling it twice is safe.
destroy :: proc(report: ^Check_Report) {
	memory := report.memory
	if memory == nil {
		return
	}
	for task in memory.tasks {
		virtual.arena_destroy(&task.arena)
		free(task, memory.allocator)
	}
	delete(memory.tasks)
	virtual.arena_destroy(&memory.arena)
	free(memory, memory.allocator)
	report^ = {}
}
