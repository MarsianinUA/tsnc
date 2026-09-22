/*
The GC heap: the cells of every TS value that needs memory (requirements 6).

One reservation of address space holds the cells. It is handed out in pages of PAGE_SIZE bytes from
a frontier that only grows, since nothing frees a page before the collector arrives (T5.2). A page
either holds slots of one size class or belongs to a run of pages that holds one large cell. A
second reservation holds the page table, one Page per reserved page, committed in step with the
frontier.

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
	base:       [^]byte, // page_limit pages of address space
	pages:      [^]Page, // one row per reserved page; the rows below page_count are committed
	page_limit: int,
	page_count: int, // the frontier: pages handed out from base
	free:       [CLASS_COUNT]^Free_Slot,
}

Heap_Error :: enum u8 {
	None,
	Out_Of_Memory, // the OS refused the reservation, or it is below one page
	Bad_Table, // a type table from the object file is malformed
}

// FREE is the type table a free slot names. heap_init refuses a program with that many tables.
@(private)
FREE :: max(abi.Type_Table_ID)

// heap_init borrows `tables`, which must outlive the heap: the runtime passes the ones the compiler
// emitted into constant data. It reserves the address space and commits nothing; the first
// allocation does.
heap_init :: proc(
	heap: ^Heap,
	tables: []abi.Type_Table,
	reserve := DEFAULT_RESERVE,
) -> Heap_Error {
	if len(abi.Builtin_Table) + len(tables) >= int(FREE) {
		return .Bad_Table
	}
	for table in tables {
		if !table_is_valid(table) {
			return .Bad_Table
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

	heap^ = {
		tables     = tables,
		base       = raw_data(cells),
		pages      = ([^]Page)(raw_data(rows)),
		page_limit = page_limit,
	}
	return .None
}

// heap_destroy gives the address space back. The runtime never calls it: its heap lives until the
// process exits.
heap_destroy :: proc(heap: ^Heap) {
	virtual.release(heap.base, uint(heap.page_limit * PAGE_SIZE))
	virtual.release(heap.pages, uint(page_table_size(heap.page_limit)))
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

// alloc answers a cell of `size` bytes, header included, zero filled but for the header, which
// names `table`. A string passes its units on top of the table's size. Running out of memory ends
// the process: no caller could do anything else.
alloc :: proc(heap: ^Heap, table: abi.Type_Table_ID, size: int) -> ^abi.Cell_Header {
	layout, known := type_table(heap, table)
	assert(known, "a cell of an unregistered type table")
	assert(size >= layout.size, "a cell smaller than its type table")

	cell: [^]byte
	if size <= MAX_SMALL {
		class := class_of(size)
		if heap.free[class] == nil {
			carve_page(heap, class)
		}
		slot := heap.free[class]
		heap.free[class] = slot.next
		cell = ([^]byte)(slot)
	} else {
		count := size / PAGE_SIZE + (1 if size % PAGE_SIZE != 0 else 0)
		first := take_pages(heap, count)
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
		cell = heap.base[first * PAGE_SIZE:]
	}

	// A cell of a header alone still clears the free list link after it, so no stale pointer stays
	// in its slot.
	intrinsics.mem_zero(cell, max(size, size_of(Free_Slot)))
	header := (^abi.Cell_Header)(cell)
	header.type_table = table
	return header
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
	case .Object, .Environment:
		if table.size < size_of(abi.Cell_Header) {
			return false
		}
		// Fields come in layout order, each after the one before it and inside the cell.
		end := size_of(abi.Cell_Header)
		for field in table.fields {
			if !slot_kind_is_valid(field.kind) {
				return false
			}
			slot_size := abi.SLOT_SIZE[field.kind]
			fits := field.offset >= end && field.offset <= table.size - slot_size
			if !fits || field.offset % size_of(u64) != 0 {
				return false
			}
			end = field.offset + slot_size
		}
		return true
	}
	return false
}

@(private)
slot_kind_is_valid :: proc(kind: abi.Slot_Kind) -> bool {
	return kind >= min(abi.Slot_Kind) && kind <= max(abi.Slot_Kind)
}

@(private)
class_of :: proc(size: int) -> int {
	for class_size, class in CLASS_SIZE {
		if size <= class_size {
			return class
		}
	}
	unreachable()
}

// carve_page threads every slot of a new page onto the free list of `class`, from the last slot
// back, so the list hands the slots out in address order.
@(private)
carve_page :: proc(heap: ^Heap, class: int) {
	index := take_pages(heap, 1)
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
}

// take_pages commits `count` pages at the frontier, and the page table rows that describe them,
// and answers the index of the first.
@(private)
take_pages :: proc(heap: ^Heap, count: int) -> int {
	first := heap.page_count
	if count > heap.page_limit - first {
		out_of_memory()
	}
	if virtual.commit(&heap.base[first * PAGE_SIZE], uint(count * PAGE_SIZE)) != nil {
		out_of_memory()
	}
	committed := page_table_size(first)
	needed := page_table_size(first + count)
	if needed > committed {
		rows := ([^]byte)(heap.pages)
		if virtual.commit(&rows[committed], uint(needed - committed)) != nil {
			out_of_memory()
		}
	}
	heap.page_count = first + count
	return first
}

// page_table_size is the size of the rows for `count` pages, rounded up to whole pages: the table is
// committed a page at a time, 8192 rows or half a gigabyte of heap per commit.
@(private)
page_table_size :: proc(count: int) -> int {
	size := count * size_of(Page)
	return (size + PAGE_SIZE - 1) / PAGE_SIZE * PAGE_SIZE
}

@(private)
out_of_memory :: proc() -> ! {
	fail.at({error = .Out_Of_Memory})
}
