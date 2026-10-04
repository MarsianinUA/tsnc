/*
The compiler's one imperative layer, by rules 1, 4 and 5 of
docs/architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers.

check_only is the `tsnc check` stage: the import closure from the entry file, parse and bind of
every file in it, the module graph, the types of every source file, a checker per partition
(checking.odin), and lower. build carries on through codegen and link, and run starts what build
wrote; both live in build.odin. has_errors is the policy between the stages. driver never prints
and never sets the exit code; main does both.

File_ID order. The lib file is 0, the entry file is 1, and an imported file takes the next number
as the breadth-first walk first reaches it, as the "Determinism" paragraph of
docs/architecture-plan-tsnc.md#interaction-map asks. The walk goes in waves: the pool parses every
file known so far at once, and only when all of them are done does this thread follow their
imports, in File_ID order. So the numbers never depend on which task finished first, and -j:1 and
-j:32 number a program alike.

Memory. One arena per file task, holding that file's tokens, AST and Bound_File, one per check task,
plus one driver arena for the file table, the path strings, the file texts and the merged
diagnostics. Everything lives until destroy, because each layer borrows from the one under it: the
AST points into the file text and the Bound_File points into the AST.

Errors. A file that cannot be read is an infrastructure failure, and it has two forms. The entry
file has no span to point at, so it comes back as a Driver_Error. Anything reached through an
import has one, the specifier, so it becomes a diagnostic like any other compile error and the
walk goes on to report the rest.
*/
package driver

import "base:runtime"
import "core:mem/virtual"
import "core:thread"

import "../ast"
import "../bind"
import "../check"
import "../codegen"
import "../diag"
import "../ir"
import "../link"
import "../lower"
import "../program"
import "../source"
import "../target"

// LLVM's backend registration and command line options are process-global, so they are set once,
// before anything can reach codegen. An @(init) procedure runs before main, and in a test binary
// before the test pool starts, which is how tests/link and tests/codegen already do it.
@(init, private)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

// LIB_TEXT is the built-in lib.d.ts, module zero of every program. It goes through the same parse
// and bind as a user file.
LIB_TEXT :: #load("../lib/lib.d.ts", string)

// LIB_PATH is what a diagnostic in the lib file prints. The file is embedded, so no path on disk
// would lead a reader anywhere.
LIB_PATH :: "lib.d.ts"

// Options is what main makes of a command line it has already checked.
Options :: struct {
	input:        string,
	output:       string, // empty names the output after input
	artifact:     Artifact,
	optimization: codegen.Optimization,
	target:       target.Target,
	jobs:         int,
	sanitize:     link.Sanitizer,
}

// Artifact is what a build produces, one enum where the command line has the two flags
// requirements 9 fixes, -emit-llvm and -emit-ir.
Artifact :: enum u8 {
	Executable, // codegen writes an object file, link makes the program out of it
	LLVM_IR, // -emit-llvm: textual LLVM IR from codegen, after the passes of -o:
	IR_Dump, // -emit-ir: the tsnc IR codegen would get, lower's at -o:none and opt's otherwise
}

Error_Kind :: enum u8 {
	None,
	Entry_Unreadable, // detail: the path, then why it could not be read
	Entry_Too_Large, // detail: the path
	Out_Of_Memory, // detail: empty
	Cross_Link, // detail: empty
	Output_Unnamable, // detail: the entry file, whose name cannot become the output's
	Output_Is_Source, // detail: the source file the output would have replaced
	Output_Directory_Missing, // detail: the directory
	Broken_IR, // detail: every violation, rendered; a compiler bug
	Codegen_Failed, // detail: the path, then what codegen answered
	Runtime_Object_Missing, // detail: the path link looked at
	Sanitized_Runtime_Missing, // detail: the path link looked at under -sanitize:address
	Sanitizer_Unsupported, // detail: empty; -sanitize:address on a target with no ASan runtime
	Link_Failed, // detail: a sentence about what the linker, or link itself, could not do
	Output_Unwritable, // detail: the path, then why
	Program_Unrunnable, // detail: the path, then why
}

// Driver_Error is a failure with no place in the source. One that has a place is a diag.Diagnostic
// instead.
Driver_Error :: struct {
	kind:   Error_Kind,
	detail: string, // owned by the report's memory; empty for None
}

// Check_Report outlives nothing: destroy invalidates the whole program at once.
Check_Report :: struct {
	// Files, trees, names and the module graph, all indexed by File_ID with the lib at zero. It is
	// empty when err says the build never started.
	program:     program.Program,
	// What the checkers learned, one entry per partition, in File_ID order.
	results:     []check.Check_Result,
	diagnostics: []diag.Diagnostic, // every phase's and driver's own, in print order
	memory:      ^Build_Memory, // owns the arenas the program lives in
}

// Build_Report holds a Check_Report rather than replacing it, so that destroy keeps owning every
// arena in one place and main renders the diagnostics of all three commands the same way.
Build_Report :: struct {
	check:  Check_Report,
	output: string, // empty when the build stopped before it wrote anything
}

// Build_Memory is touched by driver alone; a caller passes it back to destroy. An arena must not
// move: virtual.arena_allocator captures the arena by pointer, so a copied or reallocated arena
// leaves its allocator pointing at the old address. That is why Build_Memory, every File_Task and
// every Check_Task are heap-allocated, and tasks and checks hold pointers.
Build_Memory :: struct {
	arena:     virtual.Arena, // the file table, the paths, the file texts, the merged diagnostics
	lowering:  virtual.Arena, // the IR and lower's diagnostics; empty until lower runs
	tasks:     [dynamic]^File_Task, // one per File_ID, each owning its own arena
	checks:    [dynamic]^Check_Task, // one per partition, each owning its own arena
	allocator: runtime.Allocator, // where the struct above came from, for destroy
}

// check_only answers every diagnostic build would, without generating code.
@(require_results)
check_only :: proc(
	options: Options,
	allocator := context.allocator,
) -> (
	report: Check_Report,
	err: Driver_Error,
) {
	report, _, err = check_and_lower(options, allocator)
	return
}

// check_and_lower reports every error it can rather than stopping at the first: a file that fails
// to parse still gets bound, and a module that cannot be found does not end the walk. lower runs
// only on a program the front end found nothing in, and what it cannot compile yet is reported
// there alone, so `tsnc check` needs it as much as build does.
@(private)
check_and_lower :: proc(
	options: Options,
	allocator: runtime.Allocator,
) -> (
	report: Check_Report,
	program_ir: ir.Program_IR,
	err: Driver_Error,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	memory := new(Build_Memory, allocator)
	memory.allocator = allocator
	if virtual.arena_init_growing(&memory.arena) != nil {
		free(memory, allocator)
		return {}, {}, {kind = .Out_Of_Memory}
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
	c.listings = make(map[string][]string, c.arena)

	// Module zero, before anything the entry file might import.
	_ = add_file(&c, LIB_PATH, "", LIB_TEXT)

	// The memory goes back with the report even though there is nothing to report: err.detail
	// lives in that arena, so freeing it here would hand the caller a dangling string.
	if err = add_entry(&c, options.input); err.kind != .None {
		return {memory = memory}, {}, err
	}

	jobs := max(options.jobs, 1)
	pool: thread.Pool
	// The heap, not the caller's allocator: the pool's threads allocate from it too.
	thread.pool_init(&pool, runtime.heap_allocator(), jobs)
	thread.pool_start(&pool)
	defer {
		thread.pool_join(&pool)
		thread.pool_destroy(&pool)
	}

	// Growing c.files inside the loop is what makes this breadth-first: a file discovered now is
	// numbered after every file already known, and its own imports are followed in a later wave.
	for first := 0; first < len(c.files); {
		last := len(c.files)
		if parse_wave(&pool, c.memory.tasks[first:last]) != nil {
			return {memory = memory}, {}, {kind = .Out_Of_Memory}
		}
		for id in first ..< last {
			append(&c.diagnostics, ..c.memory.tasks[id].diagnostics)
			follow_requests(&c, source.File_ID(id))
		}
		first = last
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

	built, cycle_errors := program.build(c.files[:], trees, bound, imports, c.arena)
	append(&c.diagnostics, ..cycle_errors)

	// check reports in the order it reads declarations, which is not print order.
	results, check_err := run_checkers(&c, &built, &pool, jobs)
	if check_err != nil {
		return {memory = memory}, {}, {kind = .Out_Of_Memory}
	}

	diagnostics := c.diagnostics[:]
	diag.sort(diagnostics)
	report = {
		program     = built,
		results     = results,
		diagnostics = diagnostics,
		memory      = memory,
	}
	if has_errors(report) {
		return report, {}, {}
	}

	// Into the phase arena that holds the IR for the rest of a build.
	if virtual.arena_init_growing(&memory.lowering) != nil {
		return report, {}, {kind = .Out_Of_Memory}
	}
	lowering := virtual.arena_allocator(&memory.lowering)
	program_ir, report.diagnostics = lower.lower(&report.program, results, lowering)
	// The gate above left the list empty, so sorting lower's own is the whole of print order.
	diag.sort(report.diagnostics)
	return report, program_ir, {}
}

// has_errors needs only one diagnostic, because every diagnostic tsnc makes is an error. This is
// the "go to lower only without errors" policy: check_and_lower asks it between check and lower,
// build before codegen, and main turns the same answer into the exit code.
has_errors :: proc(report: Check_Report) -> bool {
	return len(report.diagnostics) > 0
}

// destroy leaves nothing the report points at valid, including the text of its diagnostics. Calling
// it twice is safe.
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
