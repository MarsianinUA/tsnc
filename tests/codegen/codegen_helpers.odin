package codegen_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ast"
import "../../src/bind"
import "../../src/check"
import "../../src/codegen"
import "../../src/diag"
import "../../src/ir"
import "../../src/lower"
import "../../src/parse"
import "../../src/program"
import "../../src/source"
import "../../src/target"

/*
Two ways to get a program into codegen.

compile_text runs one TypeScript source through the whole compiler the way driver will: the real lib
as module zero, the source as module one, then parse, bind, program, check and lower, with ir.verify
on the result. A test that gets past it has a program every layer accepted, which is what the
instructions lower emits today are tested through.

The builder helpers make a small IR by hand, the way tests/ir does, for what no TypeScript program
produces yet and for the operators an optimizing build would fold away.

Everything lives in the temp allocator, which the test runner frees between tests.
*/

// LIB_TEXT is the real lib.d.ts, embedded the way driver embeds it.
LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

MAIN :: source.File_ID(1)

// The test runner runs tests on a thread pool, so LLVM's process-global setup happens once before
// the pool starts, the way driver sets it up before its own pool.
@(init)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

// compile_text lowers one source and fails the test if any layer under codegen reported anything.
compile_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> ir.Program_IR {
	texts := [?]string{LIB_TEXT, text}
	count := len(texts)
	files := make([]source.File, count, context.temp_allocator)
	trees := make([]ast.File_AST, count, context.temp_allocator)
	bound := make([]bind.Bound_File, count, context.temp_allocator)
	// One file imports nothing: an edge would need another source.
	imports := make([][]program.Import_Edge, count, context.temp_allocator)

	for source_text, i in texts {
		path := "lib.d.ts" if i == 0 else "main.ts"
		files[i] = source.make_file(path, source_text, context.temp_allocator)
		tree, parse_diagnostics := parse.parse_file(
			source_text,
			source.File_ID(i),
			context.temp_allocator,
		)
		trees[i] = tree
		bind_diagnostics: []diag.Diagnostic
		bound[i], bind_diagnostics = bind.bind_file(&trees[i], context.temp_allocator)
		testing.expectf(
			t,
			len(parse_diagnostics) == 0,
			"%s: parse %v",
			path,
			parse_diagnostics,
			loc = loc,
		)
		testing.expectf(
			t,
			len(bind_diagnostics) == 0,
			"%s: bind %v",
			path,
			bind_diagnostics,
			loc = loc,
		)
	}

	prog, graph_diagnostics := program.build(files, trees, bound, imports, context.temp_allocator)
	testing.expectf(t, len(graph_diagnostics) == 0, "program %v", graph_diagnostics, loc = loc)

	partition := [?]source.File_ID{MAIN}
	result, check_diagnostics := check.check(&prog, partition[:], context.temp_allocator)
	testing.expectf(t, len(check_diagnostics) == 0, "check %v", check_diagnostics, loc = loc)

	results := make([]check.Check_Result, 1, context.temp_allocator)
	results[0] = result
	output, lower_diagnostics := lower.lower(&prog, results, context.temp_allocator)
	testing.expectf(t, len(lower_diagnostics) == 0, "lower %v", lower_diagnostics, loc = loc)

	violations := ir.verify(output, context.temp_allocator)
	testing.expectf(
		t,
		len(violations) == 0,
		"the IR breaks its contract: %v",
		violations,
		loc = loc,
	)
	return output
}

// llvm_text emits the module as text into dist/ and answers it. An empty answer means emit or the
// read failed, and the test has already been told.
llvm_text :: proc(
	t: ^testing.T,
	output: ^ir.Program_IR,
	name: string,
	level := codegen.Optimization.none,
	loc := #caller_location,
) -> string {
	path := fmt.tprintf("dist/codegen-%s.ll", name)
	err := codegen.emit(output, output.units[0], target.HOST, level, .LLVM_IR, path)
	if !testing.expectf(t, err == .None, "emit %s: %v", path, err, loc = loc) {
		return ""
	}
	text, read_err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, read_err == nil, "read %s: %v", path, read_err, loc = loc) {
		return ""
	}
	return string(text)
}

// expect_text fails with the whole module when a line the test asked for is missing.
expect_text :: proc(t: ^testing.T, text: string, wants: []string, loc := #caller_location) {
	for want in wants {
		testing.expectf(
			t,
			strings.contains(text, want),
			"the module lacks %q:\n%s",
			want,
			text,
			loc = loc,
		)
	}
}

// at is a span of the one source a hand built program pretends to have. codegen reads no span.
at :: proc(offset: i32) -> source.Span {
	return {file = MAIN, start = offset, end = offset + 1}
}

// declare_main adds the tsnc_main every program needs, with a body that returns at once.
declare_main :: proc(p: ^ir.Program_Builder) -> ir.Func_ID {
	main := ir.declare_func(p, abi.MAIN_SYMBOL, nil, ir.VOID, at(0))
	f := ir.begin_func(p, main)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(0))
	ir.end_func(&f)
	return main
}

// finish_program closes a hand built program and holds it to the IR contract, so a broken fixture
// fails as a fixture and not as a codegen bug.
finish_program :: proc(
	t: ^testing.T,
	p: ^ir.Program_Builder,
	main: ir.Func_ID,
	loc := #caller_location,
) -> ir.Program_IR {
	output := ir.finish(p, main, nil)
	violations := ir.verify(output, context.temp_allocator)
	testing.expectf(
		t,
		len(violations) == 0,
		"the fixture breaks the IR contract: %v",
		violations,
		loc = loc,
	)
	return output
}

// hello_program is a program whose tsnc_main prints one line through the runtime. It stands in for
// the hello world stub codegen used to carry, for the tests that link and run a real executable.
hello_program :: proc(text: string) -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	line := ir.intern_string(&p, text)
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, at(0))
	f := ir.begin_func(&p, main)
	cell := ir.emit(&f, ir.STR, ir.Const_String{text = line}, at(0))
	args := [?]ir.Value_ID{cell}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Log_String, args = args[:]}, at(0))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(0))
	ir.end_func(&f)
	return ir.finish(&p, main, nil)
}
