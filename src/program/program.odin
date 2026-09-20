/*
The whole program as one frozen value: every file, its tree, its names, and the graph its imports
draw. driver builds it once the import closure is walked; check and lower read it and never change
it.

Tables: files, trees, bound and imports are all indexed by source.File_ID, and the lib module is
LIB, number zero. imports[id] holds one edge per module request of that file, in source order. A
request that named no module of the program has no edge, because driver has already reported it: a
file that is not there is not a node of the graph.

Order: init_order lists every File_ID once, each module after the modules it imports. That is the
order the top-level code of the modules runs in, the order Node evaluates ES modules in, and the
order lower will emit the init functions in. `import type` edges are left out of it, since Node
never loads a module imported only that way and tsnc must not run its top-level code either.

Cycles: when modules import each other in a ring, there is no order in which each of them runs
after everything it imports, so they share one place in init_order and the ring goes into cycles. A
ring is a mistake only when one of its modules runs something as it loads, which
bind.Bound_File.has_side_effects reports: whichever module goes first then reads a value the next
one has not produced yet. A ring of modules that only declare types, functions and constants
holding a value of their own is allowed, as requirements 7 says. A module that imports itself is
not a ring: it always sees itself.

The order and the rings come out of one depth-first search rather than a library sort, because the
answer has to be the same on every run: roots are taken in File_ID order and edges in source order,
so nothing depends on a hash or on an address in memory.

Memory: init_order, cycles and the diagnostics come from the allocator passed in, which is meant to
be an arena; program never frees. Everything else is borrowed from driver's arenas, so the result
must not outlive them. The search works in context.temp_allocator.
*/
package program

import "../ast"
import "../bind"
import "../diag"
import "../source"

// LIB is the module every program starts with: the built-in lib.d.ts, which driver puts in before
// it reads the entry file.
LIB :: source.File_ID(0)

// Import_Edge is one module request that named a file of the program.
Import_Edge :: struct {
	// The ast.Import_Named, ast.Import_Namespace or ast.Export_Named in the importing file; the
	// same node bind.Import.request names.
	request:   ast.Node_ID,
	span:      source.Span, // the specifier, where a diagnostic about this import stands
	module:    source.File_ID, // the file the specifier named
	type_only: bool, // `import type`: erased, so it orders nothing at run time
}

// Cycle is a group of modules that import each other, so none of them loads before the rest.
Cycle :: struct {
	modules:     []source.File_ID, // two or more, in File_ID order
	has_effects: bool, // one of them runs code as it loads, which is what makes the ring an error
}

Program :: struct {
	files:      []source.File, // indexed by File_ID; files[LIB] is the lib module
	trees:      []ast.File_AST, // indexed by File_ID
	bound:      []bind.Bound_File, // indexed by File_ID
	imports:    [][]Import_Edge, // indexed by the importing File_ID, in source order
	init_order: []source.File_ID, // every File_ID once, each after the modules it imports
	cycles:     []Cycle, // in initialization order
}

// build draws the module graph and freezes it together with the tables it stands on. It borrows
// all four inputs, which must be as long as each other and indexed by File_ID, and allocates only
// the order, the rings and the diagnostics.
@(require_results)
build :: proc(
	files: []source.File,
	trees: []ast.File_AST,
	bound: []bind.Bound_File,
	imports: [][]Import_Edge,
	allocator := context.allocator,
) -> (
	program: Program,
	diagnostics: []diag.Diagnostic,
) {
	ensure(len(trees) == len(files))
	ensure(len(bound) == len(files))
	ensure(len(imports) == len(files))

	program = {
		files   = files,
		trees   = trees,
		bound   = bound,
		imports = imports,
	}
	program.init_order, program.cycles = search_modules(bound, imports, allocator)
	diagnostics = report_cycles(files, program.cycles, imports, allocator)
	return
}
