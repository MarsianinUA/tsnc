package gc_tests

import "base:sanitizer"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"

/*
What the heap tells ASan (heap.odin). Only a build with -sanitize:address can ask ASan anything, so
in any other build these tests have nothing to check and pass:

	ASAN_OPTIONS=detect_stack_use_after_return=0 odin test tests/runtime/gc -sanitize:address

A point takes 40 bytes of a 48-byte slot, and a page holds 1365 of them with 16 bytes to spare.
*/

POINT_SLOT :: 48

// TSNC_EXPECT_ASAN is set by the CI step that runs these tests under ASan, so a build that lost the
// sanitizer fails there instead of passing every test above with nothing checked.
EXPECT_ASAN :: #config(TSNC_EXPECT_ASAN, false)

@(test)
the_build_has_the_sanitizer_it_expects :: proc(t: ^testing.T) {
	has_asan := .Address in ODIN_SANITIZER_FLAGS
	testing.expect(t, has_asan || !EXPECT_ASAN, "the build lacks -sanitize:address")
}

@(test)
a_new_cell_is_addressable_for_its_size_alone :: proc(t: ^testing.T) {
	when .Address in ODIN_SANITIZER_FLAGS {
		heap: gc.Heap
		init_heap(t, &heap)
		defer gc.heap_destroy(&heap)

		point := ([^]byte)(gc.alloc(&heap, POINT, POINT_SIZE))
		expect_addressable(t, point, POINT_SIZE)
		expect_poisoned(t, point[POINT_SIZE:], POINT_SLOT - POINT_SIZE)
		// The next slot waits on the free list: its link is addressable, its body is not.
		next := point[POINT_SLOT:]
		expect_addressable(t, next, size_of(gc.Free_Slot))
		expect_poisoned(t, next[size_of(gc.Free_Slot):], POINT_SLOT - size_of(gc.Free_Slot))
		page := heap.base[page_index(&heap, point) * gc.PAGE_SIZE:]
		tail := gc.PAGE_SIZE % POINT_SLOT
		expect_poisoned(t, page[gc.PAGE_SIZE - tail:], tail)
	}
}

@(test)
a_freed_slot_is_poisoned_past_its_link_until_it_is_handed_out_again :: proc(t: ^testing.T) {
	when .Address in ODIN_SANITIZER_FLAGS {
		on_a_clean_stack(t, free_a_point)
	}
}

free_a_point :: proc(t: ^testing.T, heap: ^gc.Heap) {
	// The kept point shares the page, so the page stays Small and only the slot is freed.
	kept, dropped := keep_one_of_two_points(heap)
	scrub_stack()
	gc.collect(heap)

	cell := ([^]byte)(unhide(dropped))
	testing.expect(t, gc.owner(heap, cell) == nil, "the dropped point was kept")
	testing.expect_value(t, gc.owner(heap, kept), kept)
	expect_addressable(t, cell, size_of(gc.Free_Slot))
	expect_poisoned(t, cell[size_of(gc.Free_Slot):], POINT_SLOT - size_of(gc.Free_Slot))

	again := ([^]byte)(gc.alloc(heap, POINT, POINT_SIZE))
	testing.expect_value(t, again, cell)
	expect_addressable(t, again, POINT_SIZE)
	expect_poisoned(t, again[POINT_SIZE:], POINT_SLOT - POINT_SIZE)
}

@(private = "file")
keep_one_of_two_points :: #force_no_inline proc(
	heap: ^gc.Heap,
) -> (
	kept: ^abi.Cell_Header,
	dropped: uintptr,
) {
	kept = gc.alloc(heap, POINT, POINT_SIZE)
	dropped = hide(gc.alloc(heap, POINT, POINT_SIZE))
	return
}

LARGE_SIZE :: 2 * gc.PAGE_SIZE + 1

@(test)
a_freed_large_cell_is_poisoned_whole :: proc(t: ^testing.T) {
	when .Address in ODIN_SANITIZER_FLAGS {
		on_a_clean_stack(t, free_a_large_cell)
	}
}

free_a_large_cell :: proc(t: ^testing.T, heap: ^gc.Heap) {
	point, dropped := keep_a_point_before_a_large_cell(heap)
	scrub_stack()
	gc.collect(heap)

	cell := ([^]byte)(unhide(dropped))
	testing.expect(t, gc.owner(heap, cell) == nil, "the large cell was kept")
	expect_poisoned(t, cell, 3 * gc.PAGE_SIZE)

	// The same run serves the next large cell, and only its size is addressable.
	again := ([^]byte)(gc.alloc(heap, BLOB, LARGE_SIZE))
	testing.expect_value(t, again, cell)
	expect_addressable(t, again, LARGE_SIZE)
	expect_poisoned(t, again[LARGE_SIZE:], 3 * gc.PAGE_SIZE - LARGE_SIZE)
	testing.expect_value(t, gc.owner(heap, point), point)
}

// The point holds the first page, so the run neither starts at heap.base, which heap_init may
// leave in a register (collect_test.odin), nor comes after a free page the next run would take.
@(private = "file")
keep_a_point_before_a_large_cell :: #force_no_inline proc(
	heap: ^gc.Heap,
) -> (
	point: ^abi.Cell_Header,
	dropped: uintptr,
) {
	point = gc.alloc(heap, POINT, POINT_SIZE)
	dropped = hide(gc.alloc(heap, BLOB, LARGE_SIZE))
	return
}

expect_addressable :: proc(t: ^testing.T, p: [^]byte, size: int, loc := #caller_location) {
	poisoned := sanitizer.address_region_is_poisoned(rawptr(p), size)
	testing.expectf(t, poisoned == nil, "%p is poisoned, %p of %d", poisoned, p, size, loc = loc)
}

expect_poisoned :: proc(t: ^testing.T, p: [^]byte, size: int, loc := #caller_location) {
	for i in 0 ..< size {
		if !sanitizer.address_is_poisoned(&p[i]) {
			testing.expectf(t, false, "byte %d of %p is addressable", i, p, loc = loc)
			return
		}
	}
}
