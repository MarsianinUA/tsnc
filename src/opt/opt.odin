/*
IR to IR between lower and codegen, the `opt` row of
docs/architecture-plan-tsnc.md#package-boundaries-compiler. A pass changes how a program computes,
never what it prints, and writes what it proved into the IR: codegen guesses nothing.

Functions go in Func_ID order and nothing iterates a map, so `-emit-ir` is the same bytes at any
`-j`.
*/
package opt

import "base:runtime"

import "../ir"

optimize :: proc(p: ^ir.Program_IR, allocator := context.allocator) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	for &func in p.funcs {
		flow := ir.make_flow(func, context.temp_allocator)
		drop_unreachable(&func, &flow)
	}
	inline_calls(p, allocator)
	shapes := make([]Shape, len(p.funcs), context.temp_allocator)
	for &func, id in p.funcs {
		split_cells(p^, &func, allocator)
		shapes[id] = make_shape(func, ir.make_flow(func, context.temp_allocator))
	}
	place_cells(p, shapes)
	ranges := find_ranges(p^, shapes)
	prove_indices(p, ranges, shapes)
	narrow(p, ranges, shapes, allocator)
}

// Shape holds for every pass: none moves an instruction before narrow's end_edit.
@(private)
Shape :: struct {
	flow:   ir.Flow,
	places: []ir.Place, // by Value_ID
	header: []bool, // by Block_ID: a retreating edge enters the block
}

@(private)
make_shape :: proc(func: ir.Func, flow: ir.Flow) -> Shape {
	shape := Shape {
		flow   = flow,
		places = ir.locate_values(func, context.temp_allocator),
		header = make([]bool, len(func.blocks), context.temp_allocator),
	}
	for block in flow.order {
		for pred in flow.preds[block] {
			if flow.rank[pred] >= flow.rank[block] {
				shape.header[block] = true
			}
		}
	}
	return shape
}

// drop_unreachable leaves a block the entry never reaches only its terminator, made Unreachable,
// and takes its edges off the flow and every phi: no pass meets its code, and its values belong to
// no block. Order, ranks and dominators stay as they were.
@(private)
drop_unreachable :: proc(func: ^ir.Func, flow: ^ir.Flow) {
	for &block, id in func.blocks {
		if flow.rank[id] >= 0 {
			continue
		}
		last := block.instructions[len(block.instructions) - 1]
		func.values[last].type = ir.VOID
		func.values[last].variant = ir.Unreachable{}
		block.instructions = block.instructions[len(block.instructions) - 1:]
		flow.preds[id] = nil
	}
	for block in flow.order {
		preds := flow.preds[block]
		kept := 0
		for pred in preds {
			if flow.rank[pred] >= 0 {
				preds[kept] = pred
				kept += 1
			}
		}
		if kept == len(preds) {
			continue
		}
		flow.preds[block] = preds[:kept]
		phis: for value in func.blocks[block].instructions {
			#partial switch &v in func.values[value].variant {
			case ir.Phi:
				kept = 0
				for edge in v.incoming {
					if flow.rank[edge.block] >= 0 {
						v.incoming[kept] = edge
						kept += 1
					}
				}
				v.incoming = v.incoming[:kept]
			case:
				break phis
			}
		}
	}
}
