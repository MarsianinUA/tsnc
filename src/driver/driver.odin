/*
Build orchestration. driver is the compiler's only imperative layer: it reads files, owns every
arena, walks the import graph and hands each file its File_ID. The phases it calls are pure, so
everything they need arrives as a value plus an allocator, and they hand back data plus
diagnostics.

check_only is the `tsnc check` stage: it builds the import closure from the entry file, parses and
binds every file in it, hands the result to program for the module graph, types it with one
partition of every source file, and returns that frozen program together with every diagnostic,
already in print order. build carries on from there through lower, codegen and link, and run starts
what build wrote; both live in build.odin. The policy between the stages is has_errors: nothing
reaches lower while the program still has a mistake in it. driver never prints and never sets the
exit code; main does both.

The checker runs whatever the phases under it found. A construct outside the subset becomes a Bad
node in parse, and check gives a Bad node the error type without a word, so a file that already
failed adds no second message about the same place. That is what requirements 2.3 asks for: one
pass shows everything wrong with a program, rather than one layer at a time.

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
import "../check"
import "../codegen"
import "../diag"
import "../program"
import "../source"
import "../target"

// LLVM's backend registration and command line options are process-global, so they are set once,
// before anything can reach codegen. An @(init) procedure runs before main, and in a test binary
// before the test pool starts, which is how tests/link and tests/codegen already do it. From T6.1
// it is also what keeps the setting ahead of the thread pool.
@(init)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

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

// Artifact is what a build produces. The command line spells it as two flags, because
// requirements 9 fixes -emit-llvm and -emit-ir; inside driver it is one enum, the way the
// architecture plan asks for an artifact kind, so that every stage switches on one value.
Artifact :: enum u8 {
	Executable, // codegen writes an object file, link makes the program out of it
	LLVM_IR, // -emit-llvm: textual LLVM IR from codegen, after the passes of -o:
	IR_Dump, // -emit-ir: the tsnc IR as lower left it, which -o: says nothing about
}

Error_Kind :: enum u8 {
	None,
	Entry_Unreadable, // detail: the path, then why it could not be read
	Entry_Too_Large, // detail: the path
	Out_Of_Memory, // detail: empty
	Two_Artifacts, // detail: empty
	Nothing_To_Run, // detail: empty
	Cross_Link, // detail: empty
	Output_Unnamable, // detail: the entry file, whose name cannot become the output's
	Output_Directory_Missing, // detail: the directory
	Broken_IR, // detail: every violation, rendered; a compiler bug
	Codegen_Failed, // detail: the path, then what codegen answered
	Runtime_Object_Missing, // detail: the path link looked at
	Link_Failed, // detail: a sentence about what the linker, or link itself, could not do
	Output_Unwritable, // detail: the path, then why
	Program_Unrunnable, // detail: the path, then why
}

// Driver_Error is a failure that stops the build before it starts. A failure with a place in the
// source is a diag.Diagnostic instead.
Driver_Error :: struct {
	kind:   Error_Kind,
	detail: string, // owned by the report's memory; empty for None
}

// Check_Report is the frozen result of check_only. It outlives nothing: destroy invalidates the
// whole program at once.
Check_Report :: struct {
	// Files, trees, names and the module graph, all indexed by File_ID with the lib at zero. It is
	// empty when err says the build never started.
	program:     program.Program,
	// What the checkers learned, one entry per partition. v1 makes a single partition, and lower
	// takes the whole list, so the shape already holds for the several partitions of T6.2.
	results:     []check.Check_Result,
	diagnostics: []diag.Diagnostic, // every phase's and driver's own, in print order
	memory:      ^Build_Memory, // owns the arenas the program lives in
}

// Build_Report is what a build answers: everything check learned, plus what was written and where.
// It holds a Check_Report rather than replacing it, so that destroy keeps owning every arena in one
// place and main renders the diagnostics of all three commands the same way.
Build_Report :: struct {
	check:    Check_Report,
	artifact: Artifact,
	output:   string, // the path written; empty when the build stopped before it wrote anything
}

// Build_Memory holds every arena of one build. Only driver touches it; a caller passes it back to
// destroy. It is heap-allocated because an arena must not move: virtual.arena_allocator captures
// the arena by pointer, so a copied or reallocated arena leaves its allocator pointing at the old
// address.
Build_Memory :: struct {
	arena:     virtual.Arena, // the file table, the paths, the file texts, the merged diagnostics
	lowering:  virtual.Arena, // the IR and lower's diagnostics; empty until build reaches lower
	tasks:     [dynamic]^File_Task, // one per File_ID, each owning its own arena
	checks:    [dynamic]^Check_Task, // one per partition, each owning its own arena
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
	memory.checks = make([dynamic]^Check_Task, allocator)

	c := Closure {
		memory = memory,
		arena  = virtual.arena_allocator(&memory.arena),
	}
	c.files = make([dynamic]source.File, c.arena)
	c.absolute = make([dynamic]string, c.arena)
	c.edges = make([dynamic][dynamic]program.Import_Edge, c.arena)
	c.diagnostics = make([dynamic]diag.Diagnostic, c.arena)
	c.by_key = make(map[string]source.File_ID, c.arena)
	c.failed = make(map[string]Failure, c.arena)

	// Module zero, before anything the entry file might import.
	_ = add_file(&c, LIB_PATH, "", LIB_TEXT)

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
	imports := make([][]program.Import_Edge, count, c.arena)
	for task, i in c.memory.tasks {
		trees[i] = task.tree
		bound[i] = task.bound
		imports[i] = c.edges[i][:]
	}

	// The module graph is the last thing the walk produces, so its diagnostics join the rest
	// before the sort that puts them all in print order.
	built, cycle_errors := program.build(c.files[:], trees, bound, imports, c.arena)
	append(&c.diagnostics, ..cycle_errors)

	// The types come last, and their diagnostics join the rest before the sort that puts them all
	// in print order: check reports in the order it reads declarations, which is not print order.
	results := run_checkers(&c, &built)

	diagnostics := c.diagnostics[:]
	diag.sort(diagnostics)

	return {program = built, results = results, diagnostics = diagnostics, memory = memory}, {}
}

// has_errors reports whether the program has a mistake in it. Every diagnostic tsnc makes is an
// error, so one is enough. This is the "go to lower only without errors" policy: build asks it
// between check and lower, and main turns the same answer into the exit code.
has_errors :: proc(report: Check_Report) -> bool {
	return len(report.diagnostics) > 0
}

// destroy releases every arena of the build. Nothing the report points at is valid afterwards,
// including the text of its diagnostics. Calling it twice is safe.
destroy :: proc(report: ^Check_Report) {
	memory := report.memory
	if memory == nil {
		return
	}
	for task in memory.checks {
		virtual.arena_destroy(&task.arena)
		free(task, memory.allocator)
	}
	delete(memory.checks)
	for task in memory.tasks {
		virtual.arena_destroy(&task.arena)
		free(task, memory.allocator)
	}
	delete(memory.tasks)
	// Unconditional: a build that never reached lower left this arena zeroed, and arena_destroy on
	// an arena with no block is a no-op.
	virtual.arena_destroy(&memory.lowering)
	virtual.arena_destroy(&memory.arena)
	free(memory, memory.allocator)
	report^ = {}
}
