package gc

import "core:mem/virtual"

import "../../abi"
import "../fail"

/*
Stop the world, mark, sweep; nothing moves (requirements 6). Only the stack and the registers
spilled onto it are scanned conservatively: cells and module globals are read by their slot kinds.
*/

// collect never runs inlined: between spill_registers and the scan no value of the mutator may sit
// in a register, and inside collect none does.
collect :: #force_no_inline proc(heap: ^Heap) {
	spill_registers()
	mark_stack(heap)
	for root in heap.roots {
		mark_slot(heap, root.slot, root.kind)
	}
	drain(heap)
	sweep(heap)
	heap.trigger = max(MIN_TRIGGER, heap.used * GROWTH)

	if heap.mode == .Stress {
		if problem, _ := verify(heap); problem != .None {
			fail.at({error = .Internal}, "heap check failed", PROBLEM_TEXT[problem])
		}
	}
}

// mark_stack starts at its own frame, so the frame of collect, which holds the spilled registers,
// lies inside the scan. ASan is off: the scan reads the redzones ASan puts between locals.
@(private = "file", no_sanitize_address)
mark_stack :: #force_no_inline proc(heap: ^Heap) {
	here: uintptr
	low := uintptr(&here)
	high := uintptr(heap.stack_base)
	assert(low < high, "the stack base lies below the collection")
	for word := low; word + size_of(uintptr) <= high; word += size_of(uintptr) {
		mark_reference(heap, (^rawptr)(word)^)
	}
}

@(private = "file")
mark_slot :: proc(heap: ^Heap, slot: rawptr, kind: abi.Slot_Kind) {
	switch kind {
	case .Number, .Boolean:
	case .Ref:
		mark_reference(heap, (^rawptr)(slot)^)
	case .Tagged:
		value := (^abi.Tagged)(slot)
		#partial switch value.tag {
		case .String, .Object, .Function:
			mark_reference(heap, value.payload.ref)
		}
	}
}

// owner answers nil for a static cell, which lives in read-only data and must not be marked, and
// for a number the stack scan took for an address.
@(private = "file")
mark_reference :: proc(heap: ^Heap, p: rawptr) {
	cell := owner(heap, p)
	if cell == nil || .Marked in cell.flags {
		return
	}
	cell.flags += {.Marked}

	marks := &heap.marks
	if marks.count == marks.committed {
		if virtual.commit(&marks.cells[marks.count], PAGE_SIZE) != nil {
			out_of_memory()
		}
		marks.committed += PAGE_SIZE / size_of(^abi.Cell_Header)
	}
	marks.cells[marks.count] = cell
	marks.count += 1
}

@(private = "file")
drain :: proc(heap: ^Heap) {
	marks := &heap.marks
	for marks.count > 0 {
		marks.count -= 1
		scan_cell(heap, marks.cells[marks.count])
	}
}

@(private = "file")
scan_cell :: proc(heap: ^Heap, cell: ^abi.Cell_Header) {
	table, known := type_table(heap, cell.type_table)
	assert(known, "a cell of an unregistered type table")
	switch table.kind {
	case .String, .Buffer:
	case .Object, .Environment:
		bytes := ([^]byte)(cell)
		for field in table.fields {
			mark_slot(heap, &bytes[field.offset], field.kind)
		}
	case .Closure:
		mark_reference(heap, (^abi.Closure_Cell)(cell).env)
	case .Array:
		// elements points past the header of a Buffer cell, whose table knows nothing of the
		// elements, so the array reads them.
		array := (^abi.Array_Cell)(cell)
		if array.capacity == 0 || owner(heap, array.elements) == nil {
			return
		}
		mark_reference(heap, array.elements)
		slots := ([^]byte)(array.elements)
		for i in 0 ..< array.length {
			mark_slot(heap, &slots[i * abi.SLOT_SIZE[table.element]], table.element)
		}
	}
}

// sweep walks pages and slots from the top down, so pushing each free slot leaves every list in
// address order, as carve_page makes it.
@(private = "file")
sweep :: proc(heap: ^Heap) {
	heap.free = {}
	heap.used = 0
	for index := heap.page_count - 1; index >= 0; index -= 1 {
		page := heap.pages[index]
		#partial switch page.kind {
		case .Small:
			sweep_page(heap, index)
		case .Large:
			cell := (^abi.Cell_Header)(&heap.base[index * PAGE_SIZE])
			if .Marked in cell.flags {
				cell.flags -= {.Marked}
				heap.used += int(page.run) * PAGE_SIZE
			} else {
				free_pages(heap, index, int(page.run))
			}
		}
	}
}

@(private = "file")
sweep_page :: proc(heap: ^Heap, index: int) {
	class := int(heap.pages[index].class)
	size := CLASS_SIZE[class]
	page := heap.base[index * PAGE_SIZE:]
	above := heap.free[class]
	live := 0
	for slot := PAGE_SIZE / size - 1; slot >= 0; slot -= 1 {
		cell := (^abi.Cell_Header)(&page[slot * size])
		if cell.type_table != FREE && .Marked in cell.flags {
			cell.flags -= {.Marked}
			live += 1
			continue
		}
		free := (^Free_Slot)(cell)
		free^ = {
			header = {type_table = FREE},
			next = heap.free[class],
		}
		heap.free[class] = free
	}

	// An empty page goes back whole, so its slots leave the list again.
	if live == 0 {
		heap.free[class] = above
		free_pages(heap, index, 1)
		return
	}
	heap.used += live * size
}

// direct: a freed page stays committed, so the process never hands memory back to the OS; a
// virtual.decommit here and a commit in take_pages once benchmarks measure resident memory.
@(private = "file")
free_pages :: proc(heap: ^Heap, first, count: int) {
	for index in first ..< first + count {
		heap.pages[index] = {}
	}
	heap.first_free = min(heap.first_free, first)
}
