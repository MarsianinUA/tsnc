#+private
package opt

import "base:runtime"
import "core:slice"

import "../ir"

// Editor keeps the id of every value, and the function stays as it was until end_edit.
Editor :: struct {
	func:       ^ir.Func,
	values:     [dynamic]ir.Instruction,
	insertions: [dynamic]Insertion, // in the order they were asked for
	allocator:  runtime.Allocator,
}

@(private = "file")
Insertion :: struct {
	after: ir.Value_ID, // the instruction the new one follows
	value: ir.Value_ID,
}

begin_edit :: proc(func: ^ir.Func, allocator := context.allocator) -> Editor {
	values := make([dynamic]ir.Instruction, 0, len(func.values) + 16, allocator)
	append(&values, ..func.values)
	return {
		func = func,
		values = values,
		insertions = make([dynamic]Insertion, context.temp_allocator),
		allocator = allocator,
	}
}

// insert_after goes behind what was inserted after `after` before; `after` may be inserted itself.
insert_after :: proc(e: ^Editor, after: ir.Value_ID, instruction: ir.Instruction) -> ir.Value_ID {
	id := ir.Value_ID(len(e.values))
	append(&e.values, instruction)
	append(&e.insertions, Insertion{after = after, value = id})
	return id
}

end_edit :: proc(e: ^Editor) {
	by_after :: proc(a, b: Insertion) -> bool {
		return a.after < b.after
	}
	slice.stable_sort_by(e.insertions[:], by_after)
	// first[value] is the first insertion after `value`, -1 when none follows it.
	first := make([]i32, len(e.values), context.temp_allocator)
	slice.fill(first, -1)
	for insertion, i in e.insertions {
		if first[insertion.after] < 0 {
			first[insertion.after] = i32(i)
		}
	}

	for &block in e.func.blocks {
		if !has_insertion(first, block.instructions) {
			continue
		}
		list := make([dynamic]ir.Value_ID, 0, len(block.instructions) + 4, e.allocator)
		for value in block.instructions {
			place(e, first, &list, value)
		}
		block.instructions = list[:]
	}
	e.func.values = e.values[:]
}

@(private = "file")
has_insertion :: proc(first: []i32, values: []ir.Value_ID) -> bool {
	for value in values {
		if first[value] >= 0 {
			return true
		}
	}
	return false
}

@(private = "file")
place :: proc(e: ^Editor, first: []i32, list: ^[dynamic]ir.Value_ID, value: ir.Value_ID) {
	append(list, value)
	if first[value] < 0 {
		return
	}
	for i := int(first[value]); i < len(e.insertions) && e.insertions[i].after == value; i += 1 {
		place(e, first, list, e.insertions[i].value)
	}
}
