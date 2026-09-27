package lower_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ast"
import "../../src/bind"
import "../../src/check"
import "../../src/diag"
import "../../src/ir"
import "../../src/lower"
import "../../src/parse"
import "../../src/program"
import "../../src/source"

/*
The harness builds a whole program the way driver does and hands it to lower: the real lib as module
zero, each source as the next File_ID, then parse, bind, program, check over every source, and
lower. Any diagnostic fails the test: what lower reports is the negative corpus's to pin, and a test
of lower says nothing about a program the layers under it already refused.

Nothing here imports driver, which links codegen and llvm and would make every run of these tests
need LLVM-C.dll on PATH.

Everything lives in the temp allocator, which the test runner frees between tests.
*/

// LIB_TEXT is the real lib.d.ts, embedded the way driver embeds it: the strategy table is checked
// against the file the compiler ships and not against a copy of it.
LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

LIB :: source.File_ID(0)

// Error is a diagnostic the way a user reads it.
Error :: struct {
	code:   diag.Code,
	line:   i32,
	column: i32,
}

Lowered :: struct {
	output: ir.Program_IR,
	text:   string, // the -emit-ir dump
}

lower_sources :: proc(t: ^testing.T, sources: []string, loc := #caller_location) -> Lowered {
	texts := make([]string, len(sources) + 1, context.temp_allocator)
	texts[0] = LIB_TEXT
	copy(texts[1:], sources)

	count := len(texts)
	files := make([]source.File, count, context.temp_allocator)
	trees := make([]ast.File_AST, count, context.temp_allocator)
	bound := make([]bind.Bound_File, count, context.temp_allocator)
	imports := make([][]program.Import_Edge, count, context.temp_allocator)

	paths := make([]string, count, context.temp_allocator)
	for i in 0 ..< count {
		paths[i] = "lib.d.ts" if i == 0 else fmt.tprintf("m%d.ts", i)
	}

	for text, i in texts {
		files[i] = source.make_file(paths[i], text, context.temp_allocator)
		tree, parse_diagnostics := parse.parse_file(
			text,
			source.File_ID(i),
			context.temp_allocator,
		)
		trees[i] = tree
		bind_diagnostics: []diag.Diagnostic
		bound[i], bind_diagnostics = bind.bind_file(&trees[i], context.temp_allocator)
		imports[i] = make_edges(&trees[i], paths)

		testing.expectf(
			t,
			len(parse_diagnostics) == 0,
			"%s: parse %v",
			paths[i],
			errors_of(files, parse_diagnostics),
			loc = loc,
		)
		testing.expectf(
			t,
			len(bind_diagnostics) == 0,
			"%s: bind %v",
			paths[i],
			errors_of(files, bind_diagnostics),
			loc = loc,
		)
	}

	prog, graph_diagnostics := program.build(files, trees, bound, imports, context.temp_allocator)
	testing.expectf(t, len(graph_diagnostics) == 0, "program %v", graph_diagnostics, loc = loc)

	partition := make([]source.File_ID, len(sources), context.temp_allocator)
	for i in 0 ..< len(sources) {
		partition[i] = source.File_ID(i + 1)
	}
	result, check_diagnostics := check.check(&prog, partition, context.temp_allocator)
	testing.expectf(
		t,
		len(check_diagnostics) == 0,
		"check %v",
		errors_of(files, check_diagnostics),
		loc = loc,
	)

	results := make([]check.Check_Result, 1, context.temp_allocator)
	results[0] = result
	output, diagnostics := lower.lower(&prog, results, context.temp_allocator)
	diag.sort(diagnostics)
	testing.expectf(t, len(diagnostics) == 0, "lower %v", errors_of(files, diagnostics), loc = loc)

	violations := ir.verify(output, context.temp_allocator)
	testing.expectf(
		t,
		len(violations) == 0,
		"the IR breaks its contract: %s",
		violation_text(files, output, violations),
		loc = loc,
	)

	return {output = output, text = dump(files, output)}
}

lower_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Lowered {
	one := [1]string{text}
	return lower_sources(t, one[:], loc)
}

func_named :: proc(output: ir.Program_IR, name: string) -> (ir.Func, bool) {
	for body in output.funcs {
		if body.name == name {
			return body, true
		}
	}
	return {}, false
}

// func_prefixed finds a function whose name starts with the prefix, for a nested function or an
// arrow, whose name ends in a node number.
func_prefixed :: proc(output: ir.Program_IR, prefix: string) -> (ir.Func, bool) {
	for body in output.funcs {
		if strings.has_prefix(body.name, prefix) {
			return body, true
		}
	}
	return {}, false
}

global_named :: proc(output: ir.Program_IR, name: string) -> (ir.Global, bool) {
	for global in output.globals {
		if global.name == name {
			return global, true
		}
	}
	return {}, false
}

// instructions_of lists the instructions of one variant a function holds, in the order they were
// emitted.
instructions_of :: proc(body: ir.Func, $T: typeid) -> []T {
	out := make([dynamic]T, context.temp_allocator)
	for instruction in body.values {
		if v, is_variant := instruction.variant.(T); is_variant {
			append(&out, v)
		}
	}
	return out[:]
}

calls_to :: proc(body: ir.Func, export: abi.Runtime_Proc) -> int {
	total := 0
	for call in instructions_of(body, ir.Call_Runtime) {
		total += 1 if call.export == export else 0
	}
	return total
}

// A Call is the whole check: the verifier holds its callee to no environment and to the parameter
// count.
calls_function :: proc(output: ir.Program_IR, body: ir.Func, prefix: string) -> bool {
	for call in instructions_of(body, ir.Call) {
		if strings.has_prefix(output.funcs[call.func].name, prefix) {
			return true
		}
	}
	return false
}

tests_tags :: proc(body: ir.Func, tags: ir.Tag_Set) -> bool {
	for test in instructions_of(body, ir.Tag_Test) {
		if test.tags == tags {
			return true
		}
	}
	return false
}

// fails_unless answers the error the program fails with on one side of the branch on test: the
// check that guards a read out of a tagged value.
fails_unless :: proc(
	output: ir.Program_IR,
	body: ir.Func,
	test: ir.Value_ID,
) -> (
	error: abi.Runtime_Error,
	fails: bool,
) {
	for branch in instructions_of(body, ir.Branch) {
		if branch.condition != test {
			continue
		}
		for target in ([2]ir.Block_ID{branch.then_block, branch.else_block}) {
			block := body.blocks[target].instructions
			last := body.values[block[len(block) - 1]].variant
			if fail, is_fail := last.(ir.Fail); is_fail {
				return output.fail_sites[fail.site].error, true
			}
		}
	}
	return {}, false
}

dump :: proc(files: []source.File, output: ir.Program_IR) -> string {
	builder := strings.builder_make(context.temp_allocator)
	writer := strings.to_writer(&builder)
	_ = ir.write_program(writer, files, output)
	return strings.to_string(builder)
}

@(private = "file")
violation_text :: proc(
	files: []source.File,
	output: ir.Program_IR,
	violations: []ir.Violation,
) -> string {
	builder := strings.builder_make(context.temp_allocator)
	writer := strings.to_writer(&builder)
	for violation in violations {
		_ = ir.write_violation(writer, files, output, violation)
	}
	return strings.to_string(builder)
}

@(private = "file")
errors_of :: proc(files: []source.File, diagnostics: []diag.Diagnostic) -> []Error {
	out := make([]Error, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		at := source.position(files[d.span.file], d.span.start)
		out[i] = {
			code   = d.code,
			line   = at.line,
			column = at.column,
		}
	}
	return out
}

// make_edges is the module graph of one file, as driver builds it from paths on disk: a specifier
// names another source of the test as `"./m2"` or `"./m2.ts"`, and one that names nothing gets no
// edge, which is what driver leaves behind after reporting it.
@(private = "file")
make_edges :: proc(tree: ^ast.File_AST, paths: []string) -> []program.Import_Edge {
	edges := make([dynamic]program.Import_Edge, 0, len(tree.imports), context.temp_allocator)
	for request in tree.imports {
		path, type_only := request_path(tree, request)
		if path == ast.NO_NODE {
			continue
		}
		literal, is_literal := tree.nodes[path].variant.(ast.String_Literal)
		if !is_literal {
			continue
		}
		module, found := module_named(literal.value, paths)
		if !found {
			continue
		}
		append(
			&edges,
			program.Import_Edge {
				request = request,
				span = tree.nodes[path].span,
				module = module,
				type_only = type_only,
			},
		)
	}
	return edges[:]
}

@(private = "file")
request_path :: proc(
	tree: ^ast.File_AST,
	request: ast.Node_ID,
) -> (
	path: ast.Node_ID,
	type_only: bool,
) {
	#partial switch v in tree.nodes[request].variant {
	case ast.Import_Named:
		return v.path, v.type_only
	case ast.Import_Namespace:
		return v.path, v.type_only
	case ast.Export_Named:
		return v.path, v.type_only
	}
	return ast.NO_NODE, false
}

@(private = "file")
module_named :: proc(specifier: string, paths: []string) -> (module: source.File_ID, found: bool) {
	name := strings.trim_prefix(specifier, "./")
	for path, i in paths {
		if path == name || path == strings.concatenate({name, ".ts"}, context.temp_allocator) {
			return source.File_ID(i), true
		}
	}
	return 0, false
}
