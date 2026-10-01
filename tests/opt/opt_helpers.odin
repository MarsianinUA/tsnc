package opt_tests

import "core:fmt"
import "core:testing"

import "../../src/ir"
import "../../src/opt"
import "../harness"

Optimized :: struct {
	output: ir.Program_IR,
	after:  string, // the -emit-ir dump at -o:speed
}

optimize_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Optimized {
	files, output := harness.lower_sources(t, []string{text}, loc)
	opt.optimize(&output, context.temp_allocator)
	harness.expect_contract(t, files, output, "opt", loc)
	return {output = output, after = harness.dump(files, output)}
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

read_as :: proc(body: ir.Func, value: ir.Value_ID) -> ir.Value_ID {
	if convert, is_convert := body.values[value].variant.(ir.Convert); is_convert {
		return convert.value
	}
	return value
}
