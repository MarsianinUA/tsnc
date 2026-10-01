package lower_tests

import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../../src/source"
import "../harness"

LIB :: source.File_ID(0)

Lowered :: struct {
	output: ir.Program_IR,
	text:   string, // the -emit-ir dump
}

lower_sources :: proc(t: ^testing.T, sources: []string, loc := #caller_location) -> Lowered {
	files, output := harness.lower_sources(t, sources, loc)
	return {output = output, text = harness.dump(files, output)}
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
// check that guards a read out of a tagged value, or of a reference that may be null.
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
