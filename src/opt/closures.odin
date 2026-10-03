#+private
package opt

import "../ir"

/*
A call through a closure made or named in the same function calls its function directly, with the
closure's environment, so the inliner can copy the body and escape sees where the environment goes.
A closure that is no longer used after that is not made: nothing can tell.
*/

call_known_closures :: proc(func: ^ir.Func) {
	made := false
	for block in func.blocks {
		for value in block.instructions {
			call, is_call := func.values[value].variant.(ir.Call_Closure)
			if !is_call {
				continue
			}
			#partial switch closure in func.values[call.callee].variant {
			case ir.Make_Closure:
				func.values[value].variant = ir.Call {
					func = closure.func,
					env  = closure.env,
					args = call.args,
				}
				made = true
			case ir.Func_Ref:
				func.values[value].variant = ir.Call {
					func = closure.func,
					env  = ir.NO_VALUE,
					args = call.args,
				}
			}
		}
	}
	if made {
		drop_unused_closures(func)
	}
}

// drop_unused_closures leaves an unused Make_Closure in no block, as split leaves a cell it took
// apart.
@(private = "file")
drop_unused_closures :: proc(func: ^ir.Func) {
	used := make([]bool, len(func.values), context.temp_allocator)
	fields := make([dynamic]^ir.Value_ID, context.temp_allocator)
	for block in func.blocks {
		for value in block.instructions {
			ir.operands(&func.values[value].variant, &fields)
			for field in fields {
				used[field^] = true
			}
		}
	}
	for &block in func.blocks {
		kept := 0
		for value in block.instructions {
			_, is_closure := func.values[value].variant.(ir.Make_Closure)
			if is_closure && !used[value] {
				continue
			}
			block.instructions[kept] = value
			kept += 1
		}
		block.instructions = block.instructions[:kept]
	}
}
