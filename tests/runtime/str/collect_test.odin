package str_tests

import "base:intrinsics"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Stress mode: every allocation collects first and checks the heap after. The heap under test is a
local of the test procedure and bounds the stack scan, so the cells live in the procedures it calls,
as in tests/runtime/gc.
*/

@(test)
every_allocation_keeps_its_sources :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, .Stress)
	defer gc.heap_destroy(&heap)

	call_every_allocating_procedure(t, &heap)
	problem, _ := gc.verify(&heap)
	testing.expect_value(t, problem, gc.Heap_Problem.None)
}

// A string16 view is an interior pointer, and it alone keeps its cell: from_units copies a view of
// a cell nothing else reaches, across the collection its own allocation runs.
@(test)
a_view_keeps_its_cell :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, .Stress)
	defer gc.heap_destroy(&heap)

	copy_through_a_view(t, &heap)
}

@(private = "file")
call_every_allocating_procedure :: #force_no_inline proc(t: ^testing.T, heap: ^gc.Heap) {
	mixed := cell(heap, MIXED[:])
	padded := str.from_utf8(heap, "  Hello  ")

	expect_units(t, str.from_units(heap, str.units(mixed)[3:]), MIXED[3:])
	expect_live(t, heap, mixed, padded)
	// The first half is held only by this frame while the second half and the result allocate.
	expect_units(t, str.concat(heap, cell(heap, MIXED[:3]), cell(heap, MIXED[3:])), MIXED[:])
	expect_live(t, heap, mixed, padded)
	expect_units(t, str.unit_at(heap, mixed, 1), {0xd83d})
	expect_live(t, heap, mixed, padded)
	expect_units(t, str.slice(heap, mixed, 1, 3), {0xd83d, 0xde00})
	expect_live(t, heap, mixed, padded)
	expect_ascii(t, str.trim(heap, padded), "Hello")
	expect_live(t, heap, mixed, padded)
	expect_ascii(t, str.to_upper(heap, padded), "  HELLO  ")
	expect_live(t, heap, mixed, padded)
	expect_ascii(t, str.to_lower(heap, padded), "  hello  ")
	expect_live(t, heap, mixed, padded)
	expect_ascii(t, str.from_number(heap, 1.5), "1.5")
	expect_live(t, heap, mixed, padded)
	fixed, _ := str.to_fixed(heap, 2.5, 0)
	expect_ascii(t, fixed, "3")
	expect_live(t, heap, mixed, padded)

	expect_units(t, mixed, MIXED[:])
	expect_ascii(t, padded, "  Hello  ")
}

// expect_live checks what reading the units cannot: a freed cell keeps them until its slot is
// taken again.
@(private = "file")
expect_live :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	cells: ..^abi.String_Cell,
	loc := #caller_location,
) {
	for c in cells {
		testing.expect(t, gc.owner(heap, c) != nil, "a source cell was freed", loc = loc)
	}
}

@(private = "file")
copy_through_a_view :: #force_no_inline proc(t: ^testing.T, heap: ^gc.Heap) {
	view, hidden := view_of_a_new_cell(heap)
	scrub_stack()
	copied := str.from_units(heap, view)
	source := (^abi.Cell_Header)(unhide(hidden))
	testing.expect_value(t, gc.owner(heap, raw_data(view)), source)
	expect_ascii(t, copied, "bcdef")
}

@(private = "file")
view_of_a_new_cell :: #force_no_inline proc(heap: ^gc.Heap) -> (view: string16, hidden: uintptr) {
	// A stale copy of heap.base may keep the first slot of the heap (tests/runtime/gc), so the cell
	// under test takes the second.
	str.from_utf8(heap, "filler")
	text := str.from_utf8(heap, "abcdef")
	return str.units(text)[1:], hide(text)
}

// scrub_stack writes over the stack below its caller, where the frames of earlier calls left
// copies of the pointers they handled. One volatile store per word: LLVM deletes a call whose only
// effect is a volatile memset of a local at -o:speed. And no ASan: it would put redzones around the
// buffer, which the loop never writes.
@(private = "file", no_sanitize_address)
scrub_stack :: #force_no_inline proc() {
	buffer: [2048]u64 = ---
	for &word in buffer {
		intrinsics.volatile_store(&word, 0)
	}
}

// hide keeps an address in a form no scan takes for a pointer.
@(private = "file")
hide :: proc(p: rawptr) -> uintptr {
	return ~uintptr(p)
}

@(private = "file")
unhide :: proc(hidden: uintptr) -> rawptr {
	return rawptr(~hidden)
}
