package opt_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/bind"
import "../../src/check"
import "../../src/diag"
import "../../src/ir"
import "../../src/lower"
import "../../src/opt"
import "../../src/parse"
import "../../src/program"
import "../../src/source"

/*
The harness builds one source the way driver does, the real lib as module zero and the source as
module one, lowers it, optimizes it and holds the IR to its contract before and after. A test
asserts the decision a pass took on the optimized IR and prints its dump when it fails; the dump
before opt is there to compare with while a decision is being debugged.

Everything lives in the temp allocator, which the test runner frees between tests.
*/

LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

Optimized :: struct {
	output: ir.Program_IR,
	before: string, // the -emit-ir dump at -o:none
	after:  string, // and at -o:speed
}

optimize_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Optimized {
	texts := [?]string{LIB_TEXT, text}
	files := make([]source.File, len(texts), context.temp_allocator)
	trees := make([]ast.File_AST, len(texts), context.temp_allocator)
	bound := make([]bind.Bound_File, len(texts), context.temp_allocator)
	// One source imports nothing: an edge would need another one.
	imports := make([][]program.Import_Edge, len(texts), context.temp_allocator)

	for source_text, i in texts {
		path := "lib.d.ts" if i == 0 else "m1.ts"
		files[i] = source.make_file(path, source_text, context.temp_allocator)
		tree, parse_diagnostics := parse.parse_file(
			source_text,
			source.File_ID(i),
			context.temp_allocator,
		)
		trees[i] = tree
		bind_diagnostics: []diag.Diagnostic
		bound[i], bind_diagnostics = bind.bind_file(&trees[i], context.temp_allocator)
		testing.expectf(t, len(parse_diagnostics) == 0, "parse %v", parse_diagnostics, loc = loc)
		testing.expectf(t, len(bind_diagnostics) == 0, "bind %v", bind_diagnostics, loc = loc)
	}

	prog, graph_diagnostics := program.build(files, trees, bound, imports, context.temp_allocator)
	testing.expectf(t, len(graph_diagnostics) == 0, "program %v", graph_diagnostics, loc = loc)
	partition := [?]source.File_ID{1}
	result, check_diagnostics := check.check(&prog, partition[:], context.temp_allocator)
	testing.expectf(t, len(check_diagnostics) == 0, "check %v", check_diagnostics, loc = loc)

	results := [?]check.Check_Result{result}
	output, lower_diagnostics := lower.lower(&prog, results[:], context.temp_allocator)
	testing.expectf(t, len(lower_diagnostics) == 0, "lower %v", lower_diagnostics, loc = loc)
	expect_contract(t, files, output, "lower", loc)
	before := dump(files, output)

	opt.optimize(&output, context.temp_allocator)
	after := dump(files, output)
	expect_contract(t, files, output, "opt", loc)
	return {output = output, before = before, after = after}
}

func_named :: proc(output: ir.Program_IR, name: string) -> ir.Func {
	for body in output.funcs {
		if body.name == name {
			return body
		}
	}
	panic(fmt.tprintf("no function %s", name))
}

instructions_of :: proc(body: ir.Func, $T: typeid) -> (ids: []ir.Value_ID, variants: []T) {
	found := make([dynamic]ir.Value_ID, context.temp_allocator)
	out := make([dynamic]T, context.temp_allocator)
	for instruction, id in body.values {
		if v, is_variant := instruction.variant.(T); is_variant {
			append(&found, ir.Value_ID(id))
			append(&out, v)
		}
	}
	return found[:], out[:]
}

// counter finds the phi of a loop counter, the one a `+ 1` of itself feeds back.
counter :: proc(body: ir.Func) -> (phi: ir.Value_ID, step: ir.Value_ID, found: bool) {
	ids, phis := instructions_of(body, ir.Phi)
	for p, i in phis {
		for edge in p.incoming {
			add, is_binary := body.values[edge.value].variant.(ir.Binary)
			if !is_binary || add.op != .Add || add.left != ids[i] {
				continue
			}
			if one, is_constant := body.values[add.right].variant.(ir.Const_Number); is_constant {
				if one.value == 1 {
					return ids[i], edge.value, true
				}
			}
		}
	}
	return ir.NO_VALUE, ir.NO_VALUE, false
}

// read_as answers the value an operand stands for, through a conversion.
read_as :: proc(body: ir.Func, value: ir.Value_ID) -> ir.Value_ID {
	if convert, is_convert := body.values[value].variant.(ir.Convert); is_convert {
		return convert.value
	}
	return value
}

dump :: proc(files: []source.File, output: ir.Program_IR) -> string {
	builder := strings.builder_make(context.temp_allocator)
	_ = ir.write_program(strings.to_writer(&builder), files, output)
	return strings.to_string(builder)
}

@(private = "file")
expect_contract :: proc(
	t: ^testing.T,
	files: []source.File,
	output: ir.Program_IR,
	phase: string,
	loc: runtime.Source_Code_Location,
) {
	violations := ir.verify(output, context.temp_allocator)
	if len(violations) == 0 {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	for violation in violations {
		_ = ir.write_violation(strings.to_writer(&builder), files, output, violation)
	}
	testing.expectf(
		t,
		false,
		"the IR after %s breaks its contract:\n%s\n%s",
		phase,
		strings.to_string(builder),
		dump(files, output),
		loc = loc,
	)
}
