package codegen_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/codegen"
import "../../src/ir"
import "../../src/source"
import "../../src/target"
import "../harness"

/*
Two ways to get a program into codegen.

compile_text lowers one TypeScript source through tests/harness, the way driver will. A test that
gets past it has a program every layer accepted, which is what the instructions lower emits today
are tested through.

The builder helpers make a small IR by hand, the way tests/ir does, for what no TypeScript program
produces yet and for the operators an optimizing build would fold away.

Everything lives in the temp allocator, which the test runner frees between tests.
*/

MAIN :: source.File_ID(1)

// The test runner runs tests on a thread pool, so LLVM's process-global setup happens once before
// the pool starts, the way driver sets it up before its own pool.
@(init)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

compile_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> ir.Program_IR {
	_, output := harness.lower_sources(t, []string{text}, loc)
	return output
}

// llvm_text answers an empty text when emit or the read failed, and the test has already been told.
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

// declare_main adds the tsnc_main every program needs.
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

// hello_program stands in for the hello world stub codegen used to carry, for the tests that link
// and run a real executable.
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
