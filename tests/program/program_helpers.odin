package program_tests

import "../../src/ast"
import "../../src/bind"
import "../../src/diag"
import "../../src/program"
import "../../src/source"

// Module describes one file of a test graph. program.build reads a file's path, whether its top
// level runs code, and the modules it imports, so a test writes those three and nothing else: no
// source text, no tree and no symbol table are needed to draw the graph.
//
// imports holds indices into the same array of modules, which are the File_ID values the graph is
// built with. Module zero stands for the lib, as it does in a real program.
Module :: struct {
	path:    string,
	effects: bool,
	imports: []int,
}

Built :: struct {
	program:     program.Program,
	diagnostics: []diag.Diagnostic,
}

// build_graph keeps everything in the temp allocator, so a test frees nothing.
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

// order_names answers names rather than File_ID values, which is what a failing test should read
// like.
order_names :: proc(b: Built) -> []string {
	names := make([]string, len(b.program.init_order), context.temp_allocator)
	for module, i in b.program.init_order {
		names[i] = b.program.files[module].path
	}
	return names
}

// make_edges gives every request a span of its own, where a diagnostic about it would stand.
@(private = "file")
make_edges :: proc(
	importer: int,
	module: Module,
	allocator := context.allocator,
) -> []program.Import_Edge {
	edges := make([]program.Import_Edge, len(module.imports), allocator)
	for target, i in module.imports {
		start := i32(1000 * importer + 10 * i)
		edges[i] = {
			request = ast.Node_ID(i + 1),
			span = {file = source.File_ID(importer), start = start, end = start + 4},
			module = source.File_ID(target),
		}
	}
	return edges
}
