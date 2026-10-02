package gc

import "base:sanitizer"
import "core:mem/virtual"
import "core:strconv"
import "core:time"

import "../../abi"
import "../fail"

/*
Stop the world, mark, sweep; nothing moves (requirements 6). Only the stack and the registers
spilled onto it are scanned conservatively: cells and module globals are read by their slot kinds.
*/

// collect never runs inlined: between spill_registers and the scan no value of the mutator may sit
// in a register, and inside collect none does.
collect :: #force_no_inline proc(heap: ^Heap) {
	start := time.tick_now()
	spill_registers()
	mark_stack(heap)
	for root in heap.roots {
		mark_slot(heap, root.slot, root.kind)
	}
	drain(heap)
	marked := time.tick_now()
	heap.stats.allocated += heap.used - heap.stats.live
	sweep(heap)
	swept := time.tick_now()
	set_trigger(heap, max(MIN_TRIGGER, heap.used * GROWTH))

	stats := &heap.stats
	stats.collections += 1
	stats.marking += time.tick_diff(start, marked)
	stats.sweeping += time.tick_diff(marked, swept)
	stats.longest = max(stats.longest, time.tick_diff(start, swept))
	stats.live = heap.used

	if heap.mode == .Stress {
		if problem, at := verify(heap); problem != .None {
			// The address is the cell, page or free list where verify stopped, for a debugger.
			buf: [len("0x") + 16]byte
			copy(buf[:], "0x")
			digits := strconv.write_uint(buf[2:], u64(uintptr(at)), 16)
			address := string(buf[:2 + len(digits)])
			fail.at({error = .Internal}, "heap check failed", PROBLEM_TEXT[problem], address)
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
	case .Ref, .Ref_Or_Null, .Ref_Or_Undefined:
		mark_cell(heap, (^rawptr)(slot)^)
	case .Tagged:
		value := (^abi.Tagged)(slot)
		#partial switch value.tag {
		case .String, .Object, .Function:
			mark_cell(heap, value.payload.ref)
		}
	}
}

// Only the stack scan needs owner: a word there may be a number, or point inside a cell.
@(private = "file")
mark_reference :: proc(heap: ^Heap, p: rawptr) {
	if cell := owner(heap, p); cell != nil {
		push(heap, cell)
	}
}

// mark_cell takes a reference out of a slot, which is nil, the start of a live cell, or an address
// out of the pages (a static cell, a cell opt put on the stack); verify checks that in stress mode.
@(private = "file")
mark_cell :: proc(heap: ^Heap, p: rawptr) {
	if in_pages(heap, p) {
		push(heap, (^abi.Cell_Header)(p))
	}
}


@(private = "file")
push :: proc(heap: ^Heap, cell: ^abi.Cell_Header) {
	if .Marked in cell.flags {
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
		mark_cell(heap, (^abi.Closure_Cell)(cell).env)
	case .Array:
		// elements points past the header of a Buffer cell, whose table knows nothing of the
		// elements, so the array reads them.
		array := (^abi.Array_Cell)(cell)
		if array.capacity == 0 || !in_pages(heap, array.elements) {
			return
		}
		mark_cell(heap, rawptr(uintptr(array.elements) - size_of(abi.Cell_Header)))
		switch table.element {
		case .Number, .Boolean:
			// Nothing to follow, and a sieve's array has millions of elements.
			return
		case .Ref, .Tagged, .Ref_Or_Null, .Ref_Or_Undefined:
		}
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
	size := abi.CLASS_SIZE[class]
	page := heap.base[index * PAGE_SIZE:]
	above := heap.free[class]
	live := 0
	for slot := PAGE_SIZE / size - 1; slot >= 0; slot -= 1 {
		cell := (^abi.Cell_Header)(&page[slot * size])
		if cell.type_table != FREE {
			if .Marked in cell.flags {
				cell.flags -= {.Marked}
				live += 1
				continue
			}
			// Only a cell that dies now: a free slot's body is poisoned already, and poisoning
			// it again would cost every collection the whole heap in shadow writes.
			body := page[slot * size + size_of(abi.Free_Slot):]
			sanitizer.address_poison(body, size - size_of(abi.Free_Slot))
		}
		free := (^abi.Free_Slot)(cell)
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
	sanitizer.address_poison(&heap.base[first * PAGE_SIZE], count * PAGE_SIZE)
}
