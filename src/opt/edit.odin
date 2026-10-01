#+private
package opt

import "base:runtime"
import "core:slice"

import "../ir"

// Editor inserts instructions into one function. Every value keeps its id, an inserted one takes the
// next, and end_edit writes the new lists back into the function.
Editor :: struct {
	func:       ^ir.Func,
	values:     [dynamic]ir.Instruction,
	insertions: [dynamic]Insertion, // in the order they were asked for
	allocator:  runtime.Allocator,
}

@(private = "file")
Insertion :: struct {
	after: ir.Value_ID, // the instruction the new one follows, in its block
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

// insert_after puts the instruction right behind `after`, and behind whatever was inserted there
// before it. An inserted value may be the `after` of another.
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

	for &block in e.func.blocks {
		list := make([dynamic]ir.Value_ID, 0, len(block.instructions) + 4, e.allocator)
		for value in block.instructions {
			place(e, &list, value)
		}
		block.instructions = list[:]
	}
	e.func.values = e.values[:]
}

@(private = "file")
place :: proc(e: ^Editor, list: ^[dynamic]ir.Value_ID, value: ir.Value_ID) {
	append(list, value)
	by_value :: proc(insertion: Insertion, value: ir.Value_ID) -> slice.Ordering {
		return slice.cmp(insertion.after, value)
	}
	first, _ := slice.binary_search_by(e.insertions[:], value, by_value)
	// binary_search_by may land on any of several equal keys; the insertions after `value` start at
	// the first of them.
	for first > 0 && e.insertions[first - 1].after == value {
		first -= 1
	}
	for i := first; i < len(e.insertions) && e.insertions[i].after == value; i += 1 {
		place(e, list, e.insertions[i].value)
	}
}
