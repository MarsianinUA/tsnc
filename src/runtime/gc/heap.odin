/*
The GC heap: the cells of every TS value that needs memory (requirements 6).

One reservation of address space holds the cells. It is handed out in pages of PAGE_SIZE bytes: a
page either holds slots of one size class or belongs to a run of pages that holds one large cell.
New pages come from a frontier that only grows. A page the collector empties stays committed below
the frontier and is handed out again before the frontier moves, unless a large cell needs a longer
run of free pages than any there is: then the frontier grows. A second reservation holds the page
table, one Page per reserved page, committed in step with the frontier, and a third the mark stack
of the collector (collect.odin).

The page table plus slot arithmetic is the object start map that a conservative stack scan needs:
owner turns any address inside a live cell into the cell, the way Go finds a span and an object
index and bdwgc answers GC_base. A free slot keeps a header too, naming the FREE table, so owner
tells it from a live cell without a bitmap.

The package keeps no state: the runtime's one heap is a Heap that rt holds, and tests make their
own. Nothing here allocates through context.allocator, and the heap never becomes it.
*/
package gc

import "base:intrinsics"
import "core:mem/virtual"

import "../../abi"
import "../fail"

// PAGE_SIZE is a multiple of every OS page size, 16 KiB on arm64 macOS included, and the
// reservation grain of Windows.
PAGE_SIZE :: 64 * 1024
// MAX_SMALL is the largest cell a size class holds; a larger one takes whole pages. Half a page, as
// in Oilpan, caps what a large cell wastes at the tail of its last page.
MAX_SMALL :: PAGE_SIZE / 2
CLASS_COUNT :: 40
// DEFAULT_RESERVE is address space, not memory: only the pages handed out are committed.
DEFAULT_RESERVE :: 64 << 30
// Go's defaults: a 4 MB minimum heap, and GOGC=100, so the heap may double between collections.
MIN_TRIGGER :: 4 << 20
GROWTH :: 2

// CLASS_SIZE steps by 16 bytes up to 128, then takes four classes per doubling, as Go's classes do,
// so a cell leaves at most a fifth of its slot unused. Every size is a multiple of 16, which keeps
// every cell 16-byte aligned.
@(rodata)
CLASS_SIZE := [CLASS_COUNT]int {
	16,
	32,
	48,
	64,
	80,
	96,
	112,
	128,
	160,
	192,
	224,
	256,
	320,
	384,
	448,
	512,
	640,
	768,
	896,
	1024,
	1280,
	1536,
	1792,
	2048,
	2560,
	3072,
	3584,
	4096,
	5120,
	6144,
	7168,
	8192,
	10240,
	12288,
	14336,
	16384,
	20480,
	24576,
	28672,
	32768,
}

Page_Kind :: enum u8 {
	Free, // not handed out
	Small, // slots of one size class
	Large, // the first page of a large cell
	Large_Tail, // a later page of that cell
}

Page :: struct {
	kind:  Page_Kind,
	class: u8, // Small: index into CLASS_SIZE
	run:   u32, // Large: pages in the cell; Large_Tail: pages back to its Large page
}

// Free_Slot is what a slot holds while it waits on the free list of its class. The smallest class
// is its size.
Free_Slot :: struct {
	header: abi.Cell_Header, // type_table is FREE
	next:   ^Free_Slot,
}

Heap :: struct {
	tables:     []abi.Type_Table, // the program's, numbered after abi.BUILTIN_TABLES; borrowed
	roots:      []abi.Root, // the module globals that hold a reference; borrowed
	stack_base: rawptr, // the stack scan stops below it
	mode:       Heap_Mode,
	base:       [^]byte, // page_limit pages of address space
	pages:      [^]Page, // one row per reserved page; the rows below page_count are committed
	page_limit: int,
	page_count: int, // the frontier: pages handed out from base
	first_free: int, // no page below it is Free
	free:       [CLASS_COUNT]^Free_Slot,
	marks:      Mark_Stack,
	used:       int, // bytes of the slots and runs that hold cells
	trigger:    int,
}

Heap_Mode :: enum u8 {
	Normal,
	Stress, // collect before every allocation and check the heap after every collection
}

// Mark_Stack never overflows, so a collection needs no fallback for that: its reservation has room
// for every cell the heap can hold, a cell is pushed once, when it is marked, and takes 16 bytes
// at least.
Mark_Stack :: struct {
	cells:     [^]^abi.Cell_Header,
	count:     int,
	committed: int, // entries
}

Heap_Error :: enum u8 {
	None,
	Out_Of_Memory, // the OS refused a reservation, or it is below one page
	Bad_Table, // a type table from the object file is malformed
	Bad_Root,
}

// FREE is the type table a free slot names. heap_init refuses a program with that many tables.
@(private)
FREE :: max(abi.Type_Table_ID)

// heap_init borrows `tables` and `roots`, which must outlive the heap: the runtime passes the ones
// the compiler emitted into constant data. `stack_base` must lie above every frame that may hold a
// reference: rt.main passes a local of its own, as Ruby's RUBY_INIT_STACK takes one in main.
// Nothing is committed until the first allocation.
heap_init :: proc(
	heap: ^Heap,
	tables: []abi.Type_Table,
	roots: []abi.Root,
	stack_base: rawptr,
	mode := Heap_Mode.Normal,
	reserve := DEFAULT_RESERVE,
) -> Heap_Error {
	assert(stack_base != nil, "a heap without the base of the stack it scans")
	if len(abi.Builtin_Table) + len(tables) >= int(FREE) {
		return .Bad_Table
	}
	for table in tables {
		if !table_is_valid(table) {
			return .Bad_Table
		}
	}
	for root in roots {
		if !root_is_valid(root) {
			return .Bad_Root
		}
	}

	page_limit := reserve / PAGE_SIZE
	if page_limit < 1 {
		return .Out_Of_Memory
	}
	cells, cells_err := virtual.reserve(uint(page_limit * PAGE_SIZE))
	if cells_err != nil {
		return .Out_Of_Memory
	}
	rows, rows_err := virtual.reserve(uint(page_table_size(page_limit)))
	if rows_err != nil {
		virtual.release(raw_data(cells), len(cells))
		return .Out_Of_Memory
	}
	marks, marks_err := virtual.reserve(uint(mark_stack_size(page_limit)))
	if marks_err != nil {
		virtual.release(raw_data(cells), len(cells))
		virtual.release(raw_data(rows), len(rows))
		return .Out_Of_Memory
	}

	heap^ = {
		tables = tables,
		roots = roots,
		stack_base = stack_base,
		mode = mode,
		base = raw_data(cells),
		pages = ([^]Page)(raw_data(rows)),
		page_limit = page_limit,
		marks = {cells = ([^]^abi.Cell_Header)(raw_data(marks))},
		trigger = MIN_TRIGGER,
	}
	return .None
}

// heap_destroy gives the address space back. The runtime never calls it: its heap lives until the
// process exits.
heap_destroy :: proc(heap: ^Heap) {
	virtual.release(heap.base, uint(heap.page_limit * PAGE_SIZE))
	virtual.release(heap.pages, uint(page_table_size(heap.page_limit)))
	virtual.release(heap.marks.cells, uint(mark_stack_size(heap.page_limit)))
	heap^ = {}
}

type_table :: proc(heap: ^Heap, id: abi.Type_Table_ID) -> (table: abi.Type_Table, ok: bool) {
	index := int(id)
	if index < len(abi.Builtin_Table) {
		return abi.BUILTIN_TABLES[abi.Builtin_Table(index)], true
	}
	index -= len(abi.Builtin_Table)
	if index >= len(heap.tables) {
		return {}, false
	}
	return heap.tables[index], true
}

// table_of stops the program even under -disable-assert on a cell of an unknown table: every cell
// was allocated with a known one, so that is memory corruption.
table_of :: proc(heap: ^Heap, cell: ^abi.Cell_Header) -> abi.Type_Table {
	table, known := type_table(heap, cell.type_table)
	ensure(known, "a cell of an unregistered type table")
	return table
}

// array_table finds the program's table for an array of `element` slots. lower makes one table per
// element kind, and only for the kinds the program uses, which includes the result of every call
// that answers an array: a `string[]` exists wherever `split` is called.
array_table :: proc(
	heap: ^Heap,
	element: abi.Slot_Kind,
) -> (
	table: abi.Type_Table_ID,
	found: bool,
) {
	for program_table, i in heap.tables {
		if program_table.kind == .Array && program_table.element == element {
			return abi.Type_Table_ID(len(abi.Builtin_Table) + i), true
		}
	}
	return 0, false
}

// alloc answers a cell of `size` bytes, header included, zero filled but for the header, which
// names `table`. A string passes its units on top of the table's size. Running out of memory ends
// the process: no caller could do anything else.
//
// alloc may collect first, so a caller keeps every cell it still needs where the collector looks:
// in a local or a register, in a slot of a live cell, in a root. A reference kept only in memory
// from core, such as a [dynamic] or the scratch arena, is invisible to it (requirements 4.5).
alloc :: proc(heap: ^Heap, table: abi.Type_Table_ID, size: int) -> ^abi.Cell_Header {
	layout, known := type_table(heap, table)
	assert(known, "a cell of an unregistered type table")
	assert(size >= layout.size, "a cell smaller than its type table")

	class, count, slot_size: int
	if size <= MAX_SMALL {
		class = class_of(size)
		slot_size = CLASS_SIZE[class]
	} else {
		count = size / PAGE_SIZE + (1 if size % PAGE_SIZE != 0 else 0)
		slot_size = count * PAGE_SIZE
	}
	if heap.mode == .Stress || heap.used + slot_size > heap.trigger {
		collect(heap)
	}

	// Below the trigger the garbage of the heap is still in it, so out of room a collection comes
	// first and then the whole search again, as V8's CollectAllAvailableGarbage does before it
	// reports out of memory.
	cell, found := take_cell(heap, class, count)
	if !found {
		collect(heap)
		cell, found = take_cell(heap, class, count)
		if !found {
			out_of_memory()
		}
	}
	// Only now: the collection above recounts used from the live cells.
	heap.used += slot_size

	// A cell of a header alone still clears the free list link after it, so no stale pointer stays
	// in its slot.
	intrinsics.mem_zero(cell, max(size, size_of(Free_Slot)))
	header := (^abi.Cell_Header)(cell)
	header.type_table = table
	return header
}

// take_cell takes a slot of `class` when `count` is zero, and a run of `count` pages otherwise.
@(private)
take_cell :: proc(heap: ^Heap, class, count: int) -> (cell: [^]byte, found: bool) {
	if count == 0 {
		if heap.free[class] == nil {
			carve_page(heap, class) or_return
		}
		slot := heap.free[class]
		heap.free[class] = slot.next
		return ([^]byte)(slot), true
	}
	first := take_pages(heap, count) or_return
	heap.pages[first] = {
		kind = .Large,
		run  = u32(count),
	}
	for i in 1 ..< count {
		heap.pages[first + i] = {
			kind = .Large_Tail,
			run  = u32(i),
		}
	}
	return heap.base[first * PAGE_SIZE:], true
}

// owner is the object start map: the live cell that holds the address `p`, or nil when `p` lies
// outside the heap, past the frontier, in a free slot or in the unused tail of a page. The
// conservative stack scan hands in any word that might be a pointer, hence the rawptr.
owner :: proc(heap: ^Heap, p: rawptr) -> ^abi.Cell_Header {
	address := uintptr(p)
	base := uintptr(heap.base)
	if address < base || address - base >= uintptr(heap.page_count * PAGE_SIZE) {
		return nil
	}
	offset := int(address - base)
	index := offset / PAGE_SIZE
	page := heap.pages[index]
	switch page.kind {
	case .Free:
		return nil
	case .Small:
		size := CLASS_SIZE[page.class]
		slot := offset % PAGE_SIZE / size
		if slot >= PAGE_SIZE / size {
			return nil
		}
		cell := (^abi.Cell_Header)(&heap.base[index * PAGE_SIZE + slot * size])
		if cell.type_table == FREE {
			return nil
		}
		return cell
	case .Large:
		return (^abi.Cell_Header)(&heap.base[index * PAGE_SIZE])
	case .Large_Tail:
		return (^abi.Cell_Header)(&heap.base[(index - int(page.run)) * PAGE_SIZE])
	}
	unreachable()
}

// table_is_valid checks what the compiler wrote into the object file: a table the collector or
// console would read out of bounds is a compiler bug, and startup is the place to say so.
@(private)
table_is_valid :: proc(table: abi.Type_Table) -> bool {
	switch table.kind {
	case .String:
		return len(table.fields) == 0 && table.size == size_of(abi.String_Cell)
	case .Closure:
		return len(table.fields) == 0 && table.size == size_of(abi.Closure_Cell)
	case .Array:
		has_shape := len(table.fields) == 0 && table.size == size_of(abi.Array_Cell)
		return has_shape && slot_kind_is_valid(table.element)
	case .Buffer:
		// The builtin one is the only buffer table: the runtime alone makes buffers.
		return false
	case .Object, .Environment:
		if table.size < size_of(abi.Cell_Header) {
			return false
		}
		// Fields come in the order the console prints them, not by offset, so each one is checked
		// against every other. A table has a handful of fields, and this runs once per table.
		for field, i in table.fields {
			if !slot_kind_is_valid(field.kind) {
				return false
			}
			end := field.offset + abi.SLOT_SIZE[field.kind]
			inside := field.offset >= size_of(abi.Cell_Header) && end <= table.size
			if !inside || field.offset % size_of(u64) != 0 {
				return false
			}
			for other in table.fields[:i] {
				if field.offset < other.offset + abi.SLOT_SIZE[other.kind] && other.offset < end {
					return false
				}
			}
		}
		return true
	}
	return false
}

@(private)
slot_kind_is_valid :: proc(kind: abi.Slot_Kind) -> bool {
	return kind >= min(abi.Slot_Kind) && kind <= max(abi.Slot_Kind)
}

// The compiler lists no number or boolean global: those are no roots.
@(private)
root_is_valid :: proc(root: abi.Root) -> bool {
	aligned := root.slot != nil && uintptr(root.slot) % size_of(u64) == 0
	return aligned && (root.kind == .Ref || root.kind == .Tagged)
}

// class_of reads the class off the layout of CLASS_SIZE: steps of 16 up to 128, then four classes
// for each power of two, told apart by the two bits below the top one of size - 1.
@(private)
class_of :: proc(size: int) -> int {
	if size <= 128 {
		return (size - 1) >> 4
	}
	top := 63 - int(intrinsics.count_leading_zeros(u64(size - 1)))
	return 4 * top - 24 + ((size - 1) >> uint(top - 2))
}

// carve_page threads every slot of a new page onto the free list of `class`, from the last slot
// back, so the list hands the slots out in address order.
@(private)
carve_page :: proc(heap: ^Heap, class: int) -> (ok: bool) {
	index := take_pages(heap, 1) or_return
	heap.pages[index] = {
		kind  = .Small,
		class = u8(class),
	}
	size := CLASS_SIZE[class]
	page := heap.base[index * PAGE_SIZE:]
	next: ^Free_Slot
	for slot := PAGE_SIZE / size - 1; slot >= 0; slot -= 1 {
		free := (^Free_Slot)(&page[slot * size])
		free^ = {
			header = {type_table = FREE},
			next = next,
		}
		next = free
	}
	heap.free[class] = next
	return true
}

@(private)
take_pages :: proc(heap: ^Heap, count: int) -> (first: int, ok: bool) {
	if free, found := find_free_run(heap, count); found {
		return free, true
	}
	first = heap.page_count
	if count > heap.page_limit - first {
		return
	}
	if virtual.commit(&heap.base[first * PAGE_SIZE], uint(count * PAGE_SIZE)) != nil {
		return
	}
	committed := page_table_size(first)
	needed := page_table_size(first + count)
	if needed > committed {
		rows := ([^]byte)(heap.pages)
		if virtual.commit(&rows[committed], uint(needed - committed)) != nil {
			return
		}
	}
	heap.page_count = first + count
	return first, true
}

// direct: a linear scan of the page table from first_free; an index of free runs by length once
// profiles show large cells waiting on it.
@(private)
find_free_run :: proc(heap: ^Heap, count: int) -> (first: int, found: bool) {
	for heap.first_free < heap.page_count && heap.pages[heap.first_free].kind != .Free {
		heap.first_free += 1
	}
	run := 0
	for index in heap.first_free ..< heap.page_count {
		if heap.pages[index].kind != .Free {
			run = 0
			continue
		}
		run += 1
		if run == count {
			return index - count + 1, true
		}
	}
	return 0, false
}

// page_table_size is the size of the rows for `count` pages, rounded up to whole pages: the table is
// committed a page at a time, 8192 rows or half a gigabyte of heap per commit.
@(private)
page_table_size :: proc(count: int) -> int {
	return round_to_pages(count * size_of(Page))
}

@(private)
mark_stack_size :: proc(count: int) -> int {
	return round_to_pages(count * (PAGE_SIZE / CLASS_SIZE[0]) * size_of(^abi.Cell_Header))
}

@(private)
round_to_pages :: proc(size: int) -> int {
	return (size + PAGE_SIZE - 1) / PAGE_SIZE * PAGE_SIZE
}

@(private)
out_of_memory :: proc() -> ! {
	fail.at({error = .Out_Of_Memory})
}
