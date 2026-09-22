package gc_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"

// RESERVE lets every class carve a page and still leaves room for a few large cells.
RESERVE :: 64 * gc.PAGE_SIZE

STRING :: abi.Type_Table_ID(abi.Builtin_Table.String)
// The program tables TABLES registers, numbered after the builtin ones.
POINT :: abi.Type_Table_ID(len(abi.Builtin_Table))
ENVIRONMENT :: POINT + 1
CLOSURE :: POINT + 2
ARRAY :: POINT + 3
// BLOB has no slots, so a cell of any size fits it: it stands for an array's element buffer until
// T5.5 gives the buffer a table of its own.
BLOB :: POINT + 4

POINT_SIZE :: 40
// POINT_CLASS is the class of 48 bytes, the one a point takes.
POINT_CLASS :: 2

TABLES := []abi.Type_Table {
	{
		kind = .Object,
		size = POINT_SIZE,
		fields = {
			{name = "next", offset = 8, kind = .Ref},
			{name = "value", offset = 16, kind = .Tagged},
			{name = "x", offset = 32, kind = .Number},
		},
	},
	{kind = .Environment, size = 16, fields = {{offset = 8, kind = .Ref}}},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Ref},
	{kind = .Object, size = size_of(abi.Cell_Header)},
}

Point :: struct {
	using header: abi.Cell_Header,
	next:         ^abi.Cell_Header,
	value:        abi.Tagged,
	x:            f64,
}

#assert(size_of(Point) == POINT_SIZE)

@(test)
classes_ascend_in_steps_of_16_up_to_max_small :: proc(t: ^testing.T) {
	previous := 0
	for size in gc.CLASS_SIZE {
		testing.expectf(t, size > previous, "%d does not follow %d", size, previous)
		testing.expectf(t, size % 16 == 0, "%d is not a multiple of 16", size)
		previous = size
	}
	testing.expect_value(t, previous, gc.MAX_SMALL)
}

@(test)
a_cell_takes_the_smallest_class_that_holds_it :: proc(t: ^testing.T) {
	heap := make_heap(t)
	defer gc.heap_destroy(&heap)

	for size, class in gc.CLASS_SIZE {
		cell := gc.alloc(&heap, BLOB, size)
		expect_small(t, &heap, cell, class)
		if class + 1 < gc.CLASS_COUNT {
			expect_small(t, &heap, gc.alloc(&heap, BLOB, size + 1), class + 1)
		}
	}
	// A cell of a header alone still takes the room a free slot needs.
	expect_small(t, &heap, gc.alloc(&heap, BLOB, size_of(abi.Cell_Header)), 0)
}

@(test)
a_cell_is_zero_past_its_header :: proc(t: ^testing.T) {
	heap := make_heap(t)
	defer gc.heap_destroy(&heap)

	// Every slot of a fresh page held a free list link at the offset a string keeps its length.
	size := size_of(abi.String_Cell) + 2 * 5
	cell := (^abi.String_Cell)(gc.alloc(&heap, STRING, size))
	testing.expect_value(t, cell.header, abi.Cell_Header{type_table = STRING})
	expect_zero(t, ([^]byte)(cell)[size_of(abi.Cell_Header):size])

	// A cell of a header alone is shorter than the link, and its slot still loses it.
	bare := gc.alloc(&heap, BLOB, size_of(abi.Cell_Header))
	expect_zero(t, ([^]byte)(bare)[size_of(abi.Cell_Header):size_of(gc.Free_Slot)])
}

@(test)
cells_of_a_class_come_in_address_order_and_fill_pages :: proc(t: ^testing.T) {
	heap := make_heap(t)
	defer gc.heap_destroy(&heap)

	first := gc.alloc(&heap, POINT, POINT_SIZE)
	second := gc.alloc(&heap, POINT, POINT_SIZE)
	testing.expect_value(t, uintptr(second) - uintptr(first), 48)

	// The largest class fits twice in a page, so the third cell starts the next page.
	pages := heap.page_count
	cells: [3]^abi.Cell_Header
	for &cell in cells {
		cell = gc.alloc(&heap, BLOB, gc.MAX_SMALL)
	}
	testing.expect_value(t, heap.page_count, pages + 2)
	testing.expect_value(t, uintptr(cells[1]) - uintptr(cells[0]), gc.MAX_SMALL)
	testing.expect_value(t, page_index(&heap, cells[2]), page_index(&heap, cells[0]) + 1)
}

@(test)
a_large_cell_takes_a_run_of_whole_pages :: proc(t: ^testing.T) {
	heap := make_heap(t)
	defer gc.heap_destroy(&heap)

	one := gc.alloc(&heap, BLOB, gc.MAX_SMALL + 1)
	testing.expect_value(t, heap.pages[page_index(&heap, one)], gc.Page{kind = .Large, run = 1})
	two := gc.alloc(&heap, BLOB, 2 * gc.PAGE_SIZE)
	testing.expect_value(t, heap.pages[page_index(&heap, two)], gc.Page{kind = .Large, run = 2})

	three := gc.alloc(&heap, BLOB, 2 * gc.PAGE_SIZE + 1)
	head := page_index(&heap, three)
	testing.expect_value(t, (uintptr(three) - uintptr(heap.base)) % gc.PAGE_SIZE, 0)
	testing.expect_value(t, heap.pages[head], gc.Page{kind = .Large, run = 3})
	testing.expect_value(t, heap.pages[head + 1], gc.Page{kind = .Large_Tail, run = 1})
	testing.expect_value(t, heap.pages[head + 2], gc.Page{kind = .Large_Tail, run = 2})
	testing.expect_value(t, heap.page_count, head + 3)
}

@(test)
an_address_inside_a_cell_finds_the_cell :: proc(t: ^testing.T) {
	heap := make_heap(t)
	defer gc.heap_destroy(&heap)

	point := gc.alloc(&heap, POINT, POINT_SIZE)
	at := ([^]byte)(point)
	testing.expect_value(t, gc.owner(&heap, point), point)
	testing.expect_value(t, gc.owner(&heap, &at[20]), point)
	testing.expect_value(t, gc.owner(&heap, &at[POINT_SIZE - 1]), point)

	large := gc.alloc(&heap, BLOB, 3 * gc.PAGE_SIZE)
	inside := ([^]byte)(large)[2 * gc.PAGE_SIZE + 100:]
	testing.expect_value(t, gc.owner(&heap, inside), large)
}

@(test)
an_address_outside_every_live_cell_has_no_owner :: proc(t: ^testing.T) {
	heap := make_heap(t)
	defer gc.heap_destroy(&heap)

	point := gc.alloc(&heap, POINT, POINT_SIZE)
	page := heap.base[page_index(&heap, point) * gc.PAGE_SIZE:]
	// 1365 slots of 48 bytes leave the last 16 bytes of the page to no slot.
	testing.expect(t, gc.owner(&heap, &page[48]) == nil, "a free slot")
	testing.expect(t, gc.owner(&heap, &page[gc.PAGE_SIZE - 1]) == nil, "the tail of a page")

	frontier := heap.base[heap.page_count * gc.PAGE_SIZE:]
	testing.expect(t, gc.owner(&heap, frontier) == nil, "the frontier")
	below := rawptr(uintptr(heap.base) - 1)
	testing.expect(t, gc.owner(&heap, below) == nil, "below the heap")
	local: int
	testing.expect(t, gc.owner(&heap, &local) == nil, "the stack")
	testing.expect(t, gc.owner(&heap, &TABLES[0]) == nil, "static data")
}

@(test)
program_tables_follow_the_builtin_ones :: proc(t: ^testing.T) {
	// The reservation the runtime makes, so every OS in CI grants it.
	heap: gc.Heap
	testing.expect_value(t, gc.heap_init(&heap, TABLES), gc.Heap_Error.None)
	defer gc.heap_destroy(&heap)

	text, text_ok := gc.type_table(&heap, STRING)
	testing.expect(t, text_ok)
	testing.expect_value(t, text.kind, abi.Cell_Kind.String)
	testing.expect_value(t, text.size, size_of(abi.String_Cell))

	point, point_ok := gc.type_table(&heap, POINT)
	testing.expect(t, point_ok)
	testing.expect_value(t, point.size, POINT_SIZE)
	testing.expect_value(t, point.fields[0].name, "next")

	_, past_ok := gc.type_table(&heap, POINT + abi.Type_Table_ID(len(TABLES)))
	testing.expect(t, !past_ok, "an id past the last table")

	cell := gc.alloc(&heap, POINT, POINT_SIZE)
	testing.expect_value(t, gc.owner(&heap, cell), cell)
}

@(test)
a_malformed_table_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		table: abi.Type_Table,
	}
	cases := [?]Case {
		{"string of the wrong size", {kind = .String, size = 24}},
		{
			"field inside the header",
			{kind = .Object, size = 16, fields = {{offset = 0, kind = .Number}}},
		},
		{
			"field past the size",
			{kind = .Object, size = 16, fields = {{offset = 16, kind = .Number}}},
		},
		{
			"overlapping fields",
			{
				kind = .Object,
				size = 40,
				fields = {{offset = 8, kind = .Tagged}, {offset = 16, kind = .Number}},
			},
		},
		{
			"misaligned field",
			{kind = .Object, size = 24, fields = {{offset = 12, kind = .Number}}},
		},
		{
			"field of no slot kind",
			{kind = .Object, size = 16, fields = {{offset = 8, kind = abi.Slot_Kind(9)}}},
		},
		{"kind outside the enum", {kind = abi.Cell_Kind(9), size = 8}},
		{
			"array of no element kind",
			{kind = .Array, size = size_of(abi.Array_Cell), element = abi.Slot_Kind(9)},
		},
	}
	for c in cases {
		heap: gc.Heap
		tables := []abi.Type_Table{c.table}
		testing.expectf(
			t,
			gc.heap_init(&heap, tables, RESERVE) == .Bad_Table,
			"%s: accepted",
			c.name,
		)
	}
}

@(test)
a_reservation_the_os_cannot_give_is_out_of_memory :: proc(t: ^testing.T) {
	heap: gc.Heap
	testing.expect_value(
		t,
		gc.heap_init(&heap, nil, gc.PAGE_SIZE - 1),
		gc.Heap_Error.Out_Of_Memory,
	)
	// core:mem/virtual asserts on darwin that mmap failed with ENOMEM, and nothing promises that
	// XNU answers a size past the address space that way.
	when ODIN_OS != .Darwin {
		testing.expect_value(t, gc.heap_init(&heap, nil, 1 << 62), gc.Heap_Error.Out_Of_Memory)
	}
}

@(test)
a_heap_hands_out_every_page_it_reserved :: proc(t: ^testing.T) {
	heap := make_heap(t, 3 * gc.PAGE_SIZE)
	defer gc.heap_destroy(&heap)

	gc.alloc(&heap, BLOB, gc.PAGE_SIZE + 1)
	gc.alloc(&heap, BLOB, gc.MAX_SMALL)
	gc.alloc(&heap, BLOB, gc.MAX_SMALL)
	testing.expect_value(t, heap.page_count, heap.page_limit)
}

make_heap :: proc(t: ^testing.T, reserve := RESERVE, loc := #caller_location) -> (heap: gc.Heap) {
	err := gc.heap_init(&heap, TABLES, reserve)
	testing.expect_value(t, err, gc.Heap_Error.None, loc = loc)
	return
}

expect_zero :: proc(t: ^testing.T, bytes: []byte, loc := #caller_location) {
	for b, i in bytes {
		testing.expectf(t, b == 0, "byte %d past the header is %d", i, b, loc = loc)
	}
}

page_index :: proc(heap: ^gc.Heap, p: rawptr) -> int {
	return int(uintptr(p) - uintptr(heap.base)) / gc.PAGE_SIZE
}

expect_small :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	cell: ^abi.Cell_Header,
	class: int,
	loc := #caller_location,
) {
	page := heap.pages[page_index(heap, cell)]
	testing.expect_value(t, page, gc.Page{kind = .Small, class = u8(class)}, loc = loc)
	testing.expectf(t, uintptr(cell) % 16 == 0, "%p is not 16-byte aligned", cell, loc = loc)
}
