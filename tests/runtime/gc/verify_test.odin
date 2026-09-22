package gc_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"

// STATIC_TEXT stands for a string cell codegen puts in constant data, outside the heap.
STATIC_TEXT := abi.String_Cell {
	header = {type_table = STRING},
}

// Live is a heap with one cell of every kind, each reachable from the others.
Live :: struct {
	first:   ^Point,
	second:  ^Point,
	text:    ^abi.String_Cell,
	closure: ^abi.Closure_Cell,
	array:   ^abi.Array_Cell,
}

@(test)
an_empty_heap_is_whole :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	expect_problem(t, &heap, .None, nil)
}

@(test)
a_live_heap_is_whole :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	make_live(&heap)
	gc.alloc(&heap, BLOB, 2 * gc.PAGE_SIZE)
	expect_problem(t, &heap, .None, nil)
}

@(test)
a_reference_to_no_live_cell_dangles :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)
	live := make_live(&heap)

	// Both points take class 48, and nothing else does.
	live.first.next = (^abi.Cell_Header)(heap.free[POINT_CLASS])
	expect_problem(t, &heap, .Dangling_Reference, live.first)

	live.first.next = (^abi.Cell_Header)(uintptr(live.second) + 8)
	expect_problem(t, &heap, .Dangling_Reference, live.first)

	live.first.next = (^abi.Cell_Header)(&heap.base[heap.page_count * gc.PAGE_SIZE])
	expect_problem(t, &heap, .Dangling_Reference, live.first)
}

@(test)
a_root_to_no_live_cell_dangles :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)
	live := make_live(&heap)

	// Locals stand in for module globals: nothing collects here, so nothing has to find them.
	ref: ^abi.Cell_Header = live.first
	value := abi.Tagged {
		tag = .String,
		payload = {ref = &STATIC_TEXT},
	}
	heap.roots = []abi.Root{{slot = &ref, kind = .Ref}, {slot = &value, kind = .Tagged}}
	expect_problem(t, &heap, .None, nil)

	ref = (^abi.Cell_Header)(uintptr(live.second) + 8)
	expect_problem(t, &heap, .Dangling_Reference, &ref)
	ref = nil

	value = {
		tag = .Object,
		payload = {ref = (^abi.Cell_Header)(heap.free[POINT_CLASS])},
	}
	expect_problem(t, &heap, .Dangling_Reference, &value)
}

@(test)
a_header_names_its_problems :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)
	live := make_live(&heap)

	live.text.flags = {.Marked}
	expect_problem(t, &heap, .Stray_Mark, live.text)
	live.text.flags = {}

	live.second.type_table = POINT + 100
	expect_problem(t, &heap, .Unknown_Table, live.second)
}

@(test)
contents_that_overrun_their_table_are_bad :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)
	live := make_live(&heap)

	// Three units took class 32, which has room for eight.
	live.text.length = 9
	expect_problem(t, &heap, .Bad_Cell, live.text)
	live.text.length = 3

	live.first.value.tag = abi.Tag(42)
	expect_problem(t, &heap, .Bad_Cell, live.first)
	live.first.value.tag = .Undefined

}

@(test)
array_elements_live_in_a_buffer_cell_with_room :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)
	live := make_live(&heap)
	elements := live.array.elements
	buffer := uintptr(elements) - size_of(abi.Cell_Header)

	live.array.length = live.array.capacity + 1
	expect_problem(t, &heap, .Bad_Cell, live.array)
	live.array.length = 2

	// The buffer took class 64: seven slots after its header.
	live.array.capacity = 8
	expect_problem(t, &heap, .Bad_Cell, live.array)
	live.array.capacity = 6

	live.array.elements = rawptr(buffer)
	expect_problem(t, &heap, .Bad_Cell, live.array)

	// An empty array still writes its next push into the buffer, so the buffer is checked.
	live.array.length = 0
	live.array.elements = heap.free[POINT_CLASS]
	expect_problem(t, &heap, .Dangling_Reference, live.array)

	// Not read at all: out of the heap, it may point anywhere.
	live.array.elements = rawptr(uintptr(0x10))
	expect_problem(t, &heap, .Dangling_Reference, live.array)

	live.array.elements = elements
	expect_problem(t, &heap, .None, nil)
}

@(test)
free_lists_hold_exactly_the_free_slots :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)
	live := make_live(&heap)

	// The slot after the second point heads the free list of its class.
	head := heap.free[POINT_CLASS]
	testing.expect_value(t, uintptr(head), uintptr(live.second) + 48)

	head.next = (^gc.Free_Slot)(live.first)
	expect_problem(t, &heap, .Bad_Free_List, live.first)
	head.next = (^gc.Free_Slot)(uintptr(head) + 48)

	// A slot the program wrote to after it was freed looks live, and the list still holds it.
	free_header := head.header
	head.header.type_table = BLOB
	expect_problem(t, &heap, .Bad_Free_List, head)
	head.header = free_header

	// A cycle stops at the free slot count.
	next := head.next
	head.next = head
	expect_problem(t, &heap, .Bad_Free_List, head)
	head.next = next

	heap.free[POINT_CLASS] = head.next
	expect_problem(t, &heap, .Bad_Free_List, &heap.free[POINT_CLASS])
}

@(test)
a_page_table_that_disagrees_with_itself_is_bad :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	small := page_index(&heap, gc.alloc(&heap, POINT, POINT_SIZE))
	head := page_index(&heap, gc.alloc(&heap, BLOB, 2 * gc.PAGE_SIZE))
	testing.expect_value(t, heap.page_count, head + 2)
	// Past `small`, so the first case below makes a free page where first_free promises none.
	heap.first_free = head

	Case :: struct {
		name: string,
		page: int,
		row:  gc.Page,
	}
	cases := [?]Case {
		{"free page below first_free", small, {kind = .Free}},
		{"kind outside the enum", small, {kind = gc.Page_Kind(7)}},
		{"class outside the table", small, {kind = .Small, class = gc.CLASS_COUNT}},
		{"run of no pages", head, {kind = .Large}},
		{"run past the frontier", head, {kind = .Large, run = 3}},
		{"tail outside its run", head + 1, {kind = .Large_Tail, run = 5}},
		{"tail with no head", head, {kind = .Large_Tail, run = 1}},
	}
	for c in cases {
		saved := heap.pages[c.page]
		heap.pages[c.page] = c.row
		found, at := gc.verify(&heap)
		testing.expectf(t, found == .Bad_Page, "%s: %v", c.name, found)
		testing.expectf(t, at == &heap.base[c.page * gc.PAGE_SIZE], "%s: at %p", c.name, at)
		heap.pages[c.page] = saved
	}
	expect_problem(t, &heap, .None, nil)
}

make_live :: proc(heap: ^gc.Heap) -> (live: Live) {
	live.first = (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
	live.second = (^Point)(gc.alloc(heap, POINT, POINT_SIZE))
	live.first.next = live.second
	live.second.next = live.first

	live.text = (^abi.String_Cell)(gc.alloc(heap, STRING, size_of(abi.String_Cell) + 2 * 3))
	live.text.length = 3
	live.first.value = {
		tag = .String,
		payload = {ref = live.text},
	}
	live.second.value = {
		tag = .String,
		payload = {ref = &STATIC_TEXT},
	}

	env := gc.alloc(heap, ENVIRONMENT, 16)
	(^^abi.Cell_Header)(&([^]byte)(env)[8])^ = live.first
	live.closure = (^abi.Closure_Cell)(gc.alloc(heap, CLOSURE, size_of(abi.Closure_Cell)))
	live.closure.env = (^abi.Environment_Cell)(env)

	buffer := gc.alloc(heap, BLOB, size_of(abi.Cell_Header) + 6 * size_of(rawptr))
	live.array = (^abi.Array_Cell)(gc.alloc(heap, ARRAY, size_of(abi.Array_Cell)))
	live.array.capacity = 6
	live.array.length = 2
	live.array.elements = &([^]byte)(buffer)[size_of(abi.Cell_Header)]
	elements := ([^]^abi.Cell_Header)(live.array.elements)
	elements[0] = live.first
	elements[1] = live.closure
	return
}

expect_problem :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	problem: gc.Heap_Problem,
	at: rawptr,
	loc := #caller_location,
) {
	found, found_at := gc.verify(heap)
	testing.expect_value(t, found, problem, loc = loc)
	testing.expect_value(t, found_at, at, loc = loc)
}
