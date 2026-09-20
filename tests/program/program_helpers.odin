package program_tests

import "core:testing"

import "../../src/ast"
import "../../src/bind"
import "../../src/diag"
import "../../src/program"
import "../../src/source"

// Module describes one file of a test graph. program.build reads a file's path, whether its top
// level runs code, and the modules it imports, so a test writes those three and nothing else: no
// source text, no tree and no symbol table are needed to draw the graph.
//
// imports and type_imports hold indices into the same array of modules, which are the File_ID
// values the graph is built with. Module zero stands for the lib, as it does in a real program.
Module :: struct {
	path:         string,
	effects:      bool,
	imports:      []int, // ordinary imports: they order the modules
	type_imports: []int, // `import type`: erased, so they order nothing
}

Built :: struct {
	program:     program.Program,
	diagnostics: []diag.Diagnostic,
}

// build_graph runs program.build over a described graph. Everything lives in the temp allocator,
// so a test frees nothing.
build_graph :: proc(modules: []Module) -> Built {
	count := len(modules)
	files := make([]source.File, count, context.temp_allocator)
	trees := make([]ast.File_AST, count, context.temp_allocator)
	bound := make([]bind.Bound_File, count, context.temp_allocator)
	imports := make([][]program.Import_Edge, count, context.temp_allocator)

	for module, i in modules {
		files[i] = source.make_file(module.path, "", context.temp_allocator)
		trees[i] = {
			file = source.File_ID(i),
		}
		bound[i] = {
			has_side_effects = module.effects,
		}
		imports[i] = make_edges(i, module, context.temp_allocator)
	}

	p, diagnostics := program.build(files, trees, bound, imports, context.temp_allocator)
	return {program = p, diagnostics = diagnostics}
}

// request_span is the span build_graph gives request number `position` of `importer`, counted from
// zero over the ordinary imports and then the type-only ones. A test names it to say which import
// a diagnostic has to stand on.
request_span :: proc(importer, position: int) -> source.Span {
	start := i32(1000 * importer + 10 * position)
	return {file = source.File_ID(importer), start = start, end = start + 4}
}

// order_names is the initialization order by module name, which is what a failing test should read
// like.
order_names :: proc(b: Built) -> []string {
	names := make([]string, len(b.program.init_order), context.temp_allocator)
	for module, i in b.program.init_order {
		names[i] = b.program.files[module].path
	}
	return names
}

// cycle_names is the modules of one ring by name.
cycle_names :: proc(b: Built, cycle: int) -> []string {
	modules := b.program.cycles[cycle].modules
	names := make([]string, len(modules), context.temp_allocator)
	for module, i in modules {
		names[i] = b.program.files[module].path
	}
	return names
}

// expect_no_cycles is the answer a program without rings must give: no groups and no diagnostics.
expect_no_cycles :: proc(t: ^testing.T, b: Built, loc := #caller_location) {
	testing.expectf(t, len(b.program.cycles) == 0, "cycles %v", b.program.cycles, loc = loc)
	testing.expectf(t, len(b.diagnostics) == 0, "diagnostics %v", b.diagnostics, loc = loc)
}

@(private = "file")
make_edges :: proc(
	importer: int,
	module: Module,
	allocator := context.allocator,
) -> []program.Import_Edge {
	edges := make([]program.Import_Edge, len(module.imports) + len(module.type_imports), allocator)
	for target, i in module.imports {
		edges[i] = edge_at(importer, i, target, false)
	}
	for target, i in module.type_imports {
		position := len(module.imports) + i
		edges[position] = edge_at(importer, position, target, true)
	}
	return edges
}

@(private = "file")
edge_at :: proc(importer, position, target: int, type_only: bool) -> program.Import_Edge {
	return {
		request = ast.Node_ID(position + 1),
		span = request_span(importer, position),
		module = source.File_ID(target),
		type_only = type_only,
	}
}
