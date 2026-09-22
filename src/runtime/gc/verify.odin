package gc

import "../../abi"

Heap_Problem :: enum u8 {
	None,
	Bad_Page, // the page table disagrees with itself
	Bad_Free_List, // a free list holds something other than a free slot of its class, or loses one
	Unknown_Table, // a cell names a table that was never registered
	Bad_Cell, // a cell's contents contradict its table or overrun its slot
	Stray_Mark, // a cell is marked outside a collection
	Dangling_Reference, // a reference into the heap that is not the start of a live cell
}

// verify walks the whole heap and answers the first broken invariant with the cell, page or free
// list where it found it. It only reads. A reference out of the heap is taken as it is: that is
// where the compiler's static cells live.
verify :: proc(heap: ^Heap) -> (problem: Heap_Problem, at: rawptr) {
	// --- The page table, first: the checks below trust it when they look a reference up.
	for index := 0; index < heap.page_count; index += 1 {
		page := heap.pages[index]
		switch page.kind {
		case .Free:
		case .Small:
			if int(page.class) >= CLASS_COUNT {
				return .Bad_Page, &heap.base[index * PAGE_SIZE]
			}
		case .Large:
			count := int(page.run)
			if count < 1 || count > heap.page_count - index {
				return .Bad_Page, &heap.base[index * PAGE_SIZE]
			}
			for i in 1 ..< count {
				// Field by field: a struct compare would take the padding in as well.
				tail := heap.pages[index + i]
				if tail.kind != .Large_Tail || int(tail.run) != i {
					return .Bad_Page, &heap.base[(index + i) * PAGE_SIZE]
				}
			}
			index += count - 1
		case .Large_Tail:
			// A tail its head's run covers was skipped along with the head.
			return .Bad_Page, &heap.base[index * PAGE_SIZE]
		case:
			return .Bad_Page, &heap.base[index * PAGE_SIZE]
		}
	}

	// --- Every live cell, counting the free slots on the way.
	free_slots: [CLASS_COUNT]int
	for index := 0; index < heap.page_count; index += 1 {
		page := heap.pages[index]
		#partial switch page.kind {
		case .Small:
			size := CLASS_SIZE[page.class]
			for slot in 0 ..< PAGE_SIZE / size {
				cell := (^abi.Cell_Header)(&heap.base[index * PAGE_SIZE + slot * size])
				if cell.type_table == FREE {
					free_slots[page.class] += 1
				} else if problem = verify_cell(heap, cell, size); problem != .None {
					return problem, cell
				}
			}
		case .Large:
			cell := (^abi.Cell_Header)(&heap.base[index * PAGE_SIZE])
			if problem = verify_cell(heap, cell, int(page.run) * PAGE_SIZE); problem != .None {
				return problem, cell
			}
		}
	}

	// --- The free lists hold exactly the free slots. A list longer than the count holds a live
	// cell or a cycle, and is stopped at that point.
	for class in 0 ..< CLASS_COUNT {
		count := 0
		for slot := heap.free[class]; slot != nil; slot = slot.next {
			if count == free_slots[class] || !is_free_slot(heap, slot, class) {
				return .Bad_Free_List, slot
			}
			count += 1
		}
		if count != free_slots[class] {
			return .Bad_Free_List, &heap.free[class]
		}
	}
	return .None, nil
}

@(private = "file")
verify_cell :: proc(heap: ^Heap, cell: ^abi.Cell_Header, slot_size: int) -> Heap_Problem {
	if .Marked in cell.flags {
		return .Stray_Mark
	}
	table, known := type_table(heap, cell.type_table)
	if !known {
		return .Unknown_Table
	}
	if table.size > slot_size {
		return .Bad_Cell
	}

	bytes := ([^]byte)(cell)
	switch table.kind {
	case .String:
		text := (^abi.String_Cell)(cell)
		room := (slot_size - size_of(abi.String_Cell)) / size_of(u16)
		if text.length < 0 || text.length > room {
			return .Bad_Cell
		}
	case .Object, .Environment:
		for field in table.fields {
			if problem := verify_slot(heap, &bytes[field.offset], field.kind); problem != .None {
				return problem
			}
		}
	case .Closure:
		return verify_reference(heap, (^abi.Closure_Cell)(cell).env)
	case .Array:
		return verify_elements(heap, (^abi.Array_Cell)(cell), table.element)
	}
	return .None
}

// verify_elements reads `elements` as abi describes it: the first of `capacity` slots inside a
// heap cell of their own, after that cell's header. The buffer is checked even when the array is
// empty, since the next push writes into it.
@(private = "file")
verify_elements :: proc(heap: ^Heap, array: ^abi.Array_Cell, kind: abi.Slot_Kind) -> Heap_Problem {
	if array.length < 0 || array.length > array.capacity {
		return .Bad_Cell
	}
	if array.capacity == 0 {
		return .None
	}
	// Out of the heap, elements is not read at all: it is garbage, and reading it could crash.
	buffer := owner(heap, array.elements)
	if buffer == nil {
		return .Dangling_Reference
	}
	start := uintptr(array.elements)
	after_header := start >= uintptr(buffer) + size_of(abi.Cell_Header)
	if !after_header || start % size_of(u64) != 0 {
		return .Bad_Cell
	}
	room := int(uintptr(buffer) + uintptr(slot_of(heap, buffer)) - start)
	if array.capacity > room / abi.SLOT_SIZE[kind] {
		return .Bad_Cell
	}
	slots := ([^]byte)(array.elements)
	for i in 0 ..< array.length {
		if problem := verify_slot(heap, &slots[i * abi.SLOT_SIZE[kind]], kind); problem != .None {
			return problem
		}
	}
	return .None
}

@(private = "file")
verify_slot :: proc(heap: ^Heap, slot: rawptr, kind: abi.Slot_Kind) -> Heap_Problem {
	switch kind {
	case .Number:
	case .Boolean:
		if (^u64)(slot)^ > 1 {
			return .Bad_Cell
		}
	case .Ref:
		return verify_reference(heap, (^^abi.Cell_Header)(slot)^)
	case .Tagged:
		value := (^abi.Tagged)(slot)
		switch value.tag {
		case .Undefined, .Null, .Number:
		case .Boolean:
			if transmute(u64)value.payload.boolean > 1 {
				return .Bad_Cell
			}
		case .String, .Object, .Function:
			return verify_reference(heap, value.payload.ref)
		case:
			return .Bad_Cell
		}
	}
	return .None
}

// verify_reference takes nil, which is what a slot holds before its first store.
@(private = "file")
verify_reference :: proc(heap: ^Heap, ref: ^abi.Cell_Header) -> Heap_Problem {
	if ref == nil || !in_heap(heap, ref) {
		return .None
	}
	if owner(heap, ref) != ref {
		return .Dangling_Reference
	}
	return .None
}

@(private = "file")
is_free_slot :: proc(heap: ^Heap, slot: ^Free_Slot, class: int) -> bool {
	if !in_heap(heap, slot) {
		return false
	}
	offset := int(uintptr(slot) - uintptr(heap.base))
	if offset >= heap.page_count * PAGE_SIZE {
		return false
	}
	page := heap.pages[offset / PAGE_SIZE]
	size := CLASS_SIZE[class]
	in_class := page.kind == .Small && int(page.class) == class
	on_boundary := offset % PAGE_SIZE % size == 0 && offset % PAGE_SIZE / size < PAGE_SIZE / size
	return in_class && on_boundary && slot.header.type_table == FREE
}

// in_heap covers the whole reservation, so a reference past the frontier counts as one into the
// heap.
@(private = "file")
in_heap :: proc(heap: ^Heap, p: rawptr) -> bool {
	address := uintptr(p)
	base := uintptr(heap.base)
	return address >= base && address - base < uintptr(heap.page_limit * PAGE_SIZE)
}

// slot_of is the room the slot of a live cell gives it: its class, or its run of pages.
@(private = "file")
slot_of :: proc(heap: ^Heap, cell: ^abi.Cell_Header) -> int {
	page := heap.pages[int(uintptr(cell) - uintptr(heap.base)) / PAGE_SIZE]
	if page.kind == .Small {
		return CLASS_SIZE[page.class]
	}
	return int(page.run) * PAGE_SIZE
}
