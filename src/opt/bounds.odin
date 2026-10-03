#+private
package opt

import "base:runtime"

import "../ir"

/*
Bounds check elimination. A Bounds_Check is proved when the refined range of its index is whole and
non-negative and one of these bounds it from above:
- the true edge of `index < length` or `length > index`, on every path to the check;
- a constant index below the constant length of an array literal;
- an earlier check of the same array, whose answer the index is.
An array's length changes only inside a call or a Set_Length, so neither may stand between the
bound and the check. A string never shrinks: only an owned join grows one, in place (str.join).
*/

prove_indices :: proc(p: ^ir.Program_IR, ranges: Ranges, shapes: []Shape) {
	for &func, id in p.funcs {
		fr := ranges.funcs[id]
		for block in shapes[id].flow.order {
			for value in func.blocks[block].instructions {
				#partial switch &v in func.values[value].variant {
				case ir.Bounds_Check:
					v.proved = v.proved || proved(func, fr, shapes[id], value, block, v)
				}
			}
		}
	}
}

@(private = "file")
proved :: proc(
	func: ir.Func,
	fr: Func_Ranges,
	shape: Shape,
	value: ir.Value_ID,
	block: ir.Block_ID,
	check: ir.Bounds_Check,
) -> bool {
	index := refined(fr, check.index, block)
	if index.kind != .Integral || index.lo < 0 {
		return false
	}
	since := upper_bound(func, fr, block, check)
	if since == ir.NO_VALUE {
		return false
	}
	never_shrinks := func.values[check.array].type == ir.STR
	return never_shrinks || no_call_between(func, shape, since, value)
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
	earlier, after_check := func.values[check.index].variant.(ir.Bounds_Check)
	if after_check && earlier.array == check.array {
		return check.index
	}

	if made, is_new := func.values[check.array].variant.(ir.New_Array); is_new {
		length, length_known := func.values[made.length].variant.(ir.Const_Number)
		at, at_known := func.values[check.index].variant.(ir.Const_Number)
		if length_known && at_known && at.value < length.value {
			return check.array
		}
	}

	for fact in fr.facts[check.index] {
		if !fact.holds || !ir.dominates(fr.flow, fact.block, block) {
			continue
		}
		compare := fact.compare
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
no_call_between :: proc(func: ir.Func, shape: Shape, from, to: ir.Value_ID) -> bool {
	flow := shape.flow
	start, end := shape.places[from], shape.places[to]
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
		if seen[block] {
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
		case ir.Call, ir.Call_Closure, ir.Call_Runtime, ir.Set_Length:
			return true
		}
	}
	return false
}
