#+private
package opt

import "base:runtime"

import "../ir"

/*
Bounds check elimination. A Bounds_Check becomes a Proved_Index when the refined range of its index
is whole and non-negative and one of these bounds it from above:
- the true edge of `index < length` or `length > index`, on every path to the check;
- a constant index below the constant length of an array literal;
- an earlier check of the same array, whose answer the index is.
An array's length changes only inside a call, so no call may stand between the bound and the
check. A string never changes.
*/

prove_indices :: proc(p: ^ir.Program_IR, ranges: Ranges) {
	for &func, id in p.funcs {
		fr := ranges.funcs[id]
		places := locate(func)
		for block in fr.flow.order {
			for value in func.blocks[block].instructions {
				check, is_check := func.values[value].variant.(ir.Bounds_Check)
				if is_check && proved(func, fr, places, value, block, check) {
					func.values[value].variant = ir.Proved_Index {
						array = check.array,
						index = check.index,
					}
				}
			}
		}
	}
}

@(private = "file")
Place :: struct {
	block:    ir.Block_ID,
	position: int, // inside the block
}

@(private = "file")
locate :: proc(func: ir.Func) -> []Place {
	places := make([]Place, len(func.values), context.temp_allocator)
	for block, id in func.blocks {
		for value, position in block.instructions {
			places[value] = {ir.Block_ID(id), position}
		}
	}
	return places
}

@(private = "file")
proved :: proc(
	func: ir.Func,
	fr: Func_Ranges,
	places: []Place,
	value: ir.Value_ID,
	block: ir.Block_ID,
	check: ir.Bounds_Check,
) -> bool {
	index := refined(fr, func, check.index, block)
	if index.kind != .Integral || index.lo < 0 {
		return false
	}
	since := upper_bound(func, fr, block, check)
	if since == ir.NO_VALUE {
		return false
	}
	immutable := func.values[check.array].type == ir.STR
	return immutable || no_call_between(func, fr.flow, places, since, value)
}

// upper_bound answers the first value after which the index lies below the length, NO_VALUE when
// none does.
@(private = "file")
upper_bound :: proc(
	func: ir.Func,
	fr: Func_Ranges,
	block: ir.Block_ID,
	check: ir.Bounds_Check,
) -> ir.Value_ID {
	#partial switch earlier in func.values[check.index].variant {
	case ir.Bounds_Check:
		if earlier.array == check.array {
			return check.index
		}
	case ir.Proved_Index:
		if earlier.array == check.array {
			return check.index
		}
	}

	if made, is_new := func.values[check.array].variant.(ir.New_Array); is_new {
		length, length_known := func.values[made.length].variant.(ir.Const_Number)
		at, at_known := func.values[check.index].variant.(ir.Const_Number)
		if length_known && at_known && at.value < length.value {
			return check.array
		}
	}

	for walk := fr.fact[block]; walk != ir.NO_BLOCK; walk = fr.fact[fr.flow.idom[walk]] {
		compare, holds, _ := fact_of(fr, func, walk)
		if !holds {
			continue
		}
		length := ir.NO_VALUE
		if compare.op == .Less && compare.left == check.index {
			length = compare.right
		} else if compare.op == .Greater && compare.right == check.index {
			length = compare.left
		}
		if length == ir.NO_VALUE {
			continue
		}
		measured, is_length := func.values[length].variant.(ir.Length)
		if is_length && measured.value == check.array {
			return length
		}
	}
	return ir.NO_VALUE
}

@(private = "file")
no_call_between :: proc(
	func: ir.Func,
	flow: ir.Flow,
	places: []Place,
	from, to: ir.Value_ID,
) -> bool {
	start, end := places[from], places[to]
	start_block := func.blocks[start.block].instructions
	end_block := func.blocks[end.block].instructions
	if start.block == end.block && start.position < end.position {
		// A pass that comes round to this block again computes `from` again before it reaches `to`.
		return !calls_in(func, start_block[start.position + 1:end.position])
	}
	if calls_in(func, end_block[:end.position]) {
		return false
	}

	// Kept until optimize returns, this scratch would grow by every block for every check.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Blocks whose whole body lies on a path; the walk stops at the block of `from`.
	seen := make([]bool, len(func.blocks), context.temp_allocator)
	stack := make([dynamic]ir.Block_ID, context.temp_allocator)
	append(&stack, ..flow.preds[end.block])
	for len(stack) > 0 {
		block := pop(&stack)
		if seen[block] || flow.rank[block] < 0 {
			continue
		}
		seen[block] = true
		if block == start.block {
			if calls_in(func, start_block[start.position + 1:]) {
				return false
			}
			continue
		}
		if calls_in(func, func.blocks[block].instructions) {
			return false
		}
		append(&stack, ..flow.preds[block])
	}
	return true
}

@(private = "file")
calls_in :: proc(func: ir.Func, values: []ir.Value_ID) -> bool {
	for value in values {
		#partial switch _ in func.values[value].variant {
		case ir.Call, ir.Call_Closure, ir.Call_Runtime:
			return true
		}
	}
	return false
}
