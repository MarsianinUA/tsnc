/*
IR to IR between lower and codegen, the `opt` row of
docs/architecture-plan-tsnc.md#package-boundaries-compiler. A pass changes how a program computes,
never what it prints, and writes what it proved into the IR, where ir.verify checks it: codegen
guesses nothing.

Functions go in Func_ID order and nothing iterates a map, so `-emit-ir` is the same bytes at any
`-j`.
*/
package opt

import "base:runtime"

import "../ir"

optimize :: proc(p: ^ir.Program_IR, allocator := context.allocator) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	place_cells(p)
	ranges := find_ranges(p^)
	prove_indices(p, ranges)
	narrow(p, ranges, allocator)
}

// home_blocks gives NO_BLOCK to a value no block holds.
@(private)
home_blocks :: proc(func: ir.Func) -> []ir.Block_ID {
	home := make([]ir.Block_ID, len(func.values), context.temp_allocator)
	for &block in home {
		block = ir.NO_BLOCK
	}
	for block, id in func.blocks {
		for value in block.instructions {
			home[value] = ir.Block_ID(id)
		}
	}
	return home
}
