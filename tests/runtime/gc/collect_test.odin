package gc_tests

import "base:intrinsics"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"

/*
The heap under test is a local of the test procedure and bounds the stack scan (init_heap), so the
cells a test needs live in the procedures it calls.

The scan is conservative: a stale copy of a pointer in a dead frame below the stack pointer keeps
its cell alive once a later frame covers it without writing over it. A test that expects a cell to
be freed therefore keeps its address hidden (hide) and calls scrub_stack before collect. One cell
may stay anyway: at -o:speed heap_init is inlined, and the test keeps heap.base, the address of the
first slot of the first page, in a register. No test expects that slot to be freed.

Such a test also runs its heap through on_a_clean_stack. The words an earlier test left on the
same thread lie where this test's frames land, and a new heap often takes the address range the
last one gave back, so an old pointer can name a cell of this heap. It did on a CI runner: a slot
that only a number held was kept.
*/

// COLLECT_RESERVE leaves room for a heap that grows to MIN_TRIGGER several times over.
COLLECT_RESERVE :: 1024 * gc.PAGE_SIZE
// A round of the garbage loop drops some 600 bytes, so GARBAGE rounds drop about thirty times
// MIN_TRIGGER, some 1800 pages.
GARBAGE :: 200_000
LIVE :: 64

@(test)
a_live_set_on_the_stack_survives_many_collections :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, reserve = COLLECT_RESERVE)
	defer gc.heap_destroy(&heap)

	keep_live_set_through_garbage(t, &heap, GARBAGE)
	// The garbage alone would take some 1800 pages.
	bound := 2 * gc.MIN_TRIGGER / gc.PAGE_SIZE
	testing.expectf(t, heap.page_count <= bound, "%d pages, over %d", heap.page_count, bound)
	testing.expect_value(t, STATIC_TEXT.flags, abi.Cell_Flags{})
}

@(test)
stress_mode_collects_before_every_allocation :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, mode = .Stress)
	defer gc.heap_destroy(&heap)

	// Every collection runs verify and ends the process on a problem, so reaching the end is the
	// check that each one left the heap whole.
	keep_live_set_through_garbage(t, &heap, 3000)
	// The loop dropped about two megabytes, and a normal heap would not have collected once. The
	// live set is a few kilobytes; the bound leaves room for a stale copy of the last large cell.
	testing.expectf(t, heap.used < 512 * 1024, "%d bytes in use", heap.used)
}

// More live cells than one page of the mark stack holds.
@(test)
a_wide_array_grows_the_mark_stack :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, reserve = COLLECT_RESERVE)
	defer gc.heap_destroy(&heap)

	keep_a_wide_array(t, &heap)
}

@(test)
a_collection_frees_what_nothing_reaches_and_reuses_it_in_address_order :: proc(t: ^testing.T) {
	on_a_clean_stack(t, reuse_the_dropped_slots)
}

@(test)
empty_pages_go_back_and_serve_any_class :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	drop_pages(&heap)
	scrub_stack()
	gc.collect(&heap)
	pages := heap.page_count
	free := 0
	for i in 0 ..< pages {
		free += 1 if heap.pages[i].kind == .Free else 0
	}
	// Eight pages of points and three runs of three pages; a stray word may keep one of them.
	testing.expectf(t, free >= 8 + 3 * 3 - 3, "%d of %d pages free", free, pages)

	// A class the dropped points never took, then a large cell, both on freed pages.
	gc.alloc(&heap, BLOB, 1000)
	gc.alloc(&heap, BLOB, 2 * gc.PAGE_SIZE)
	testing.expect_value(t, heap.page_count, pages)
	expect_problem(t, &heap, .None, nil)
}

@(test)
only_reference_slots_keep_a_cell :: proc(t: ^testing.T) {
	on_a_clean_stack(t, collect_past_scalar_slots)
}

@(test)
an_interior_pointer_on_the_stack_keeps_its_cell :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	collect_holding_interior_pointers(t, &heap)
}

@(private = "file")
module_ref: ^abi.Cell_Header
@(private = "file")
module_value: abi.Tagged

@(test)
module_roots_are_read_by_their_kind :: proc(t: ^testing.T) {
	roots := []abi.Root{{slot = &module_ref, kind = .Ref}, {slot = &module_value, kind = .Tagged}}
	on_a_clean_stack(t, collect_module_roots, roots)
}

// Eight pages of address space and fifty cells of a page each, none of them kept: far below the
// trigger, the heap runs out of pages and has to collect before it may report out of memory.
@(test)
a_full_heap_collects_before_it_gives_up :: proc(t: ^testing.T) {
	on_a_clean_stack(t, allocate_past_the_reservation, reserve = 8 * gc.PAGE_SIZE)
}

allocate_past_the_reservation :: proc(t: ^testing.T, heap: ^gc.Heap) {
	for _ in 0 ..< 50 {
		gc.alloc(heap, BLOB, gc.MAX_SMALL + 1)
	}
	testing.expect_value(t, heap.page_count, 8)
	cells := 0
	for i in 0 ..< heap.page_count {
		cells += 1 if heap.pages[i].kind == .Large else 0
	}
	// The cell the last collection made room for counts too.
	testing.expect_value(t, heap.used, cells * gc.PAGE_SIZE)
	expect_problem(t, heap, .None, nil)
}

// on_a_clean_stack runs `scenario` on a new heap whose stack base lies in a frame scrub_stack has
// just cleared, so every word the scan reads was written by this test.
on_a_clean_stack :: proc(
	t: ^testing.T,
	scenario: proc(t: ^testing.T, heap: ^gc.Heap),
	roots: []abi.Root = nil,
	reserve := RESERVE,
) {
	scrub_stack()
	run_on_new_heap(t, scenario, roots, reserve)
}

@(private = "file")
run_on_new_heap :: #force_no_inline proc(
	t: ^testing.T,
	scenario: proc(t: ^testing.T, heap: ^gc.Heap),
	roots: []abi.Root,
	reserve: int,
) {
	heap: gc.Heap
	init_heap(t, &heap, roots, reserve = reserve)
	defer gc.heap_destroy(&heap)

	scenario(t, &heap)
}

collect_module_roots :: proc(t: ^testing.T, heap: ^gc.Heap) {
	kept, dropped := fill_module_globals(heap)
	scrub_stack()
	gc.collect(heap)
	testing.expect_value(t, gc.owner(heap, unhide(kept)), (^abi.Cell_Header)(unhide(kept)))
	testing.expect(t, gc.owner(heap, unhide(dropped)) == nil, "a number root kept its cell")
	expect_problem(t, heap, .None, nil)
}

@(test)
the_trigger_follows_what_a_collection_leaves :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, reserve = COLLECT_RESERVE)
	defer gc.heap_destroy(&heap)

	collect_around_a_large_cell(t, &heap)
}

keep_live_set_through_garbage :: proc(t: ^testing.T, heap: ^gc.Heap, garbage: int) {
	points: [LIVE]^Point
	previous: ^Point
	for &point, i in points {
		point = (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
		point.x = f64(i)
		point.next = previous
		previous = point
		point.value = {
			tag = .String,
			payload = {ref = make_text(heap, i)},
		}
	}
	live := make_live(heap)

	for i in 0 ..< garbage {
		junk := (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
		junk.next = junk
		junk.x = f64(i)
		make_text(heap, i % 300)
		if i % 997 == 0 {
			gc.alloc(heap, BLOB, 2 * gc.PAGE_SIZE + 1)
		}
	}

	previous = nil
	for point, i in points {
		testing.expect_value(t, point.type_table, POINT)
		testing.expect_value(t, point.x, f64(i))
		testing.expect_value(t, point.next, (^abi.Cell_Header)(previous))
		previous = point
		testing.expect_value(t, point.value.tag, abi.Tag.String)
		expect_text(t, (^abi.String_Cell)(point.value.payload.ref), i)
	}
	testing.expect_value(t, live.first.next, (^abi.Cell_Header)(live.second))
	testing.expect_value(t, live.second.next, (^abi.Cell_Header)(live.first))
	testing.expect_value(t, live.first.value.payload.ref, (^abi.Cell_Header)(live.text))
	testing.expect_value(t, live.text.length, 3)
	env := ([^]byte)(live.closure.env)
	testing.expect_value(t, (^^abi.Cell_Header)(&env[8])^, (^abi.Cell_Header)(live.first))
	elements := ([^]^abi.Cell_Header)(live.array.elements)
	testing.expect_value(t, elements[0], (^abi.Cell_Header)(live.first))
	testing.expect_value(t, elements[1], (^abi.Cell_Header)(live.closure))
	expect_problem(t, heap, .None, nil)
}

reuse_the_dropped_slots :: proc(t: ^testing.T, heap: ^gc.Heap) {
	kept := keep_every_other(heap)
	scrub_stack()
	gc.collect(heap)
	expect_problem(t, heap, .None, nil)
	// The free list hands the freed slots out from the lowest address up.
	for point in kept {
		again := gc.alloc(heap, POINT, POINT_SIZE)
		testing.expect_value(t, uintptr(again), uintptr(point) + 48)
	}
}

@(private = "file")
keep_every_other :: #force_no_inline proc(heap: ^gc.Heap) -> (kept: [10]^Point) {
	for i in 0 ..< 2 * len(kept) {
		point := (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
		if i % 2 == 0 {
			kept[i / 2] = point
		}
	}
	return
}

WIDE :: 3 * (gc.PAGE_SIZE / size_of(rawptr))

keep_a_wide_array :: proc(t: ^testing.T, heap: ^gc.Heap) {
	buffer := gc.alloc(heap, BLOB, size_of(abi.Cell_Header) + WIDE * size_of(rawptr))
	array := (^abi.Array_Cell)(gc.alloc(heap, ARRAY, size_of(abi.Array_Cell)))
	array.capacity = WIDE
	array.elements = &([^]byte)(buffer)[size_of(abi.Cell_Header)]
	elements := ([^]^Point)(array.elements)
	for i in 0 ..< WIDE {
		elements[i] = (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
		elements[i].x = f64(i)
		array.length = i + 1
	}

	gc.collect(heap)
	for i in 0 ..< WIDE {
		point := elements[i]
		if point.type_table != POINT || point.x != f64(i) {
			testing.expectf(t, false, "element %d lost its point", i)
			break
		}
	}
	testing.expectf(t, heap.marks.committed >= WIDE, "%d entries committed", heap.marks.committed)
	expect_problem(t, heap, .None, nil)
}

@(private = "file")
drop_pages :: #force_no_inline proc(heap: ^gc.Heap) {
	for _ in 0 ..< 8 * (gc.PAGE_SIZE / 48) {
		gc.alloc(heap, POINT, POINT_SIZE)
	}
	for _ in 0 ..< 3 {
		gc.alloc(heap, BLOB, 2 * gc.PAGE_SIZE + 1)
	}
}

collect_past_scalar_slots :: proc(t: ^testing.T, heap: ^gc.Heap) {
	holder, array, hidden, kept := hide_in_scalar_slots(heap)
	scrub_stack()
	gc.collect(heap)

	for cell, i in hidden {
		testing.expectf(t, gc.owner(heap, unhide(cell)) == nil, "hidden cell %d was kept", i)
	}
	for cell in kept {
		testing.expect_value(t, gc.owner(heap, unhide(cell)), (^abi.Cell_Header)(unhide(cell)))
	}
	testing.expect_value(t, holder.type_table, POINT)
	testing.expect_value(t, array.length, 1)
	expect_problem(t, heap, .None, nil)
}

@(private = "file")
hide_in_scalar_slots :: #force_no_inline proc(
	heap: ^gc.Heap,
) -> (
	holder: ^Point,
	array: ^abi.Array_Cell,
	hidden: [3]uintptr,
	kept: [2]uintptr,
) {
	holder = (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
	second := (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
	object := gc.alloc(heap, POINT, POINT_SIZE)
	number := gc.alloc(heap, POINT, POINT_SIZE)
	tagged_number := gc.alloc(heap, POINT, POINT_SIZE)
	past_length := gc.alloc(heap, POINT, POINT_SIZE)

	// Followed: a Ref slot, and a tagged slot whose tag holds a reference.
	holder.next = second
	second.value = {
		tag = .Object,
		payload = {ref = object},
	}
	// Not followed: a number slot, a tagged number, an element past the length.
	holder.x = transmute(f64)uintptr(number)
	holder.value = {
		tag = .Number,
		payload = {ref = tagged_number},
	}
	buffer := gc.alloc(heap, BLOB, size_of(abi.Cell_Header) + 2 * size_of(rawptr))
	array = (^abi.Array_Cell)(gc.alloc(heap, ARRAY, size_of(abi.Array_Cell)))
	array.capacity = 2
	array.length = 1
	array.elements = &([^]byte)(buffer)[size_of(abi.Cell_Header)]
	elements := ([^]^abi.Cell_Header)(array.elements)
	elements[0] = holder
	elements[1] = past_length

	hidden = {hide(number), hide(tagged_number), hide(past_length)}
	kept = {hide(second), hide(object)}
	return
}

collect_holding_interior_pointers :: proc(t: ^testing.T, heap: ^gc.Heap) {
	inside_small, inside_large := interior_pointers(heap)
	scrub_stack()
	gc.collect(heap)

	small := (^Point)(gc.owner(heap, inside_small))
	if testing.expect(t, small != nil, "the small cell was freed") {
		testing.expect_value(t, small.x, 7)
	}
	large := gc.owner(heap, inside_large)
	if testing.expect(t, large != nil, "the large cell was freed") {
		testing.expect_value(t, large.type_table, BLOB)
	}
}

@(private = "file")
interior_pointers :: #force_no_inline proc(
	heap: ^gc.Heap,
) -> (
	inside_small, inside_large: rawptr,
) {
	small := (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
	small.x = 7
	large := gc.alloc(heap, BLOB, 3 * gc.PAGE_SIZE)
	return &([^]byte)(small)[20], &([^]byte)(large)[2 * gc.PAGE_SIZE + 100]
}

@(private = "file")
fill_module_globals :: #force_no_inline proc(heap: ^gc.Heap) -> (kept, dropped: uintptr) {
	cell := gc.alloc(heap, POINT, POINT_SIZE)
	module_ref = cell
	other := gc.alloc(heap, POINT, POINT_SIZE)
	module_value = {
		tag = .Number,
		payload = {ref = other},
	}
	return hide(cell), hide(other)
}

collect_around_a_large_cell :: proc(t: ^testing.T, heap: ^gc.Heap) {
	gc.collect(heap)
	testing.expect_value(t, heap.used, 0)
	testing.expect_value(t, heap.trigger, gc.MIN_TRIGGER)

	// Over half of MIN_TRIGGER, so GROWTH and not MIN_TRIGGER sets the next trigger.
	large := gc.alloc(heap, BLOB, 3 * gc.MIN_TRIGGER / 4)
	gc.collect(heap)
	testing.expect_value(t, heap.used, 3 * gc.MIN_TRIGGER / 4)
	testing.expect_value(t, heap.trigger, 3 * gc.MIN_TRIGGER / 2)
	testing.expect_value(t, large.type_table, BLOB)
}

make_text :: proc(heap: ^gc.Heap, length: int) -> ^abi.String_Cell {
	size := size_of(abi.String_Cell) + length * size_of(u16)
	text := (^abi.String_Cell)(gc.alloc(heap, STRING, size))
	text.length = length
	units := ([^]u16)(&text.units)
	for i in 0 ..< length {
		units[i] = u16('a' + i % 26)
	}
	return text
}

expect_text :: proc(t: ^testing.T, text: ^abi.String_Cell, length: int, loc := #caller_location) {
	testing.expect_value(t, text.type_table, STRING, loc = loc)
	if !testing.expect_value(t, text.length, length, loc = loc) {
		return
	}
	units := ([^]u16)(&text.units)
	for i in 0 ..< length {
		testing.expect_value(t, units[i], u16('a' + i % 26), loc = loc)
	}
}

// scrub_stack writes over the stack below its caller, where the frames of earlier calls left
// copies of the pointers they handled. One volatile store per word: LLVM deletes a call whose
// only effect is a volatile memset of a local, as mem_zero_volatile is, at -o:speed. And no ASan:
// it would put redzones around the buffer, which the loop never writes.
@(no_sanitize_address)
scrub_stack :: #force_no_inline proc() {
	buffer: [2048]u64 = ---
	for &word in buffer {
		intrinsics.volatile_store(&word, 0)
	}
}

// hide keeps an address in a form no scan takes for a pointer, so a test can ask about a cell
// without keeping it alive.
hide :: proc(p: rawptr) -> uintptr {
	return ~uintptr(p)
}

unhide :: proc(hidden: uintptr) -> rawptr {
	return rawptr(~hidden)
}
