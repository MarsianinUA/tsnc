/*
IR to IR between lower and codegen, the `opt` row of
docs/architecture-plan-tsnc.md#package-boundaries-compiler. A pass changes how a program computes,
never what it prints, and states what it proved as IR a verifier can check: a cell type, an
instruction, an integer type. Nothing is guessed later in codegen.

The passes, in the order optimize runs them:
- escape: a cell no reference to which outlives its function goes on the stack of that function.
  LLVM then splits it into registers where it can; opt has no scalar replacement of its own.
- ranges: the values each number may take, for the two passes below. It rewrites nothing.
- bounds: a Bounds_Check the ranges and a length test before it prove becomes a Proved_Index.
- narrow: a number proved an integer in the safe range becomes an I32 or an I64.

Functions go in Func_ID order and nothing iterates a map, so `-emit-ir` is the same bytes at any
`-j`.

Memory: what the IR keeps comes from `allocator`; the analyses are scratch in
context.temp_allocator, which optimize rewinds unless it is `allocator`.
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

// home_blocks answers the block each value stands in, NO_BLOCK for one that stands in none.
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
