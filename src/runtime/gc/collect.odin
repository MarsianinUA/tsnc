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

Marks stick, as in JavaScriptCore: a cell a collection kept stays marked, which makes it old, and a
cell made since is young. A minor collection marks from the stack, the roots and the old cells the
write barrier remembered, and stops at every marked cell, so it traces young cells only; its sweep
skips each page the last sweep left full, since no young cell can lie there. A full collection takes
every mark off first. One comes once minor collections have kept more than the last full one left,
and more than MIN_TRIGGER, which gives back the old cells that died since.
*/

// collect never runs inlined: between spill_registers and the scan no value of the mutator may sit
// in a register, and inside collect none does. Stress mode checks the heap before marking, where
// the write barrier's invariant holds, and so after the last collection too.
collect :: #force_no_inline proc(heap: ^Heap, full := false) {
	if heap.mode == .Stress {
		check(heap)
	}
	start := time.tick_now()
	whole := full || heap.next_full
	if whole {
		unmark(heap)
	}
	spill_registers()
	mark_stack(heap)
	for root in heap.roots {
		mark_slot(heap, root.slot, root.kind)
	}
	drain(heap)
	marked := time.tick_now()
	heap.stats.allocated += heap.used - heap.stats.live
	sweep(heap, whole)
	swept := time.tick_now()
	if whole {
		heap.full_live = heap.used
	}
	// MIN_TRIGGER keeps a heap where little lives from running full collections over pages it hardly
	// uses. Stress mode takes turns, so that both kinds run under it.
	kept := heap.used - heap.full_live
	heap.next_full = !whole if heap.mode == .Stress else kept > max(heap.full_live, MIN_TRIGGER)
	set_trigger(heap, max(MIN_TRIGGER, heap.full_live * GROWTH) + kept)

	stats := &heap.stats
	stats.collections += 1
	stats.full += int(whole)
	stats.marking += time.tick_diff(start, marked)
	stats.sweeping += time.tick_diff(marked, swept)
	stats.longest = max(stats.longest, time.tick_diff(start, swept))
	stats.live = heap.used
}

@(private = "file")
check :: proc(heap: ^Heap) {
	if problem, at := verify(heap); problem != .None {
		// The address is the cell, page or free list where verify stopped, for a debugger.
		buf: [len("0x") + 16]byte
		copy(buf[:], "0x")
		digits := strconv.write_uint(buf[2:], u64(uintptr(at)), 16)
		address := string(buf[:2 + len(digits)])
		fail.at({error = .Internal}, "heap check failed", PROBLEM_TEXT[problem], address)
	}
}

// write_barrier is what generated code runs after it stores a reference (build_barrier in codegen),
// for a runtime procedure that stores one into a cell that may be old.
write_barrier :: proc(heap: ^Heap, cell: ^abi.Cell_Header) {
	if cell.flags & {.Marked, .Remembered} == {.Marked} {
		remember(heap, cell)
	}
}

// unmark makes every cell young. The remembered cells leave the mark stack: marking reaches each
// one again if it still lives.
@(private = "file")
unmark :: proc(heap: ^Heap) {
	heap.marks.count = 0
	for index in 0 ..< heap.page_count {
		page := heap.pages[index]
		#partial switch page.kind {
		case .Small:
			size := abi.CLASS_SIZE[page.class]
			cells := heap.base[index * PAGE_SIZE:]
			for slot in 0 ..< PAGE_SIZE / size {
				cell := (^abi.Cell_Header)(&cells[slot * size])
				// Free slots too: writing only a header with a flag spares their cache lines.
				if cell.flags != {} {
					cell.flags = {}
				}
			}
		case .Large:
			(^abi.Cell_Header)(&heap.base[index * PAGE_SIZE]).flags = {}
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
	case .Ref, .Ref_Or_Null, .Ref_Or_Undefined, .Any_Ref, .Any_Ref_Or_Null, .Any_Ref_Or_Undefined:
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


// remember is the slow path of the write barrier (abi.Cell_Flag): the cell waits on the mark stack
// for the next collection, which scans it as it scans a cell it marks.
remember :: proc(heap: ^Heap, cell: ^abi.Cell_Header) {
	cell.flags += {.Remembered}
	gray(heap, cell)
}

@(private = "file")
push :: proc(heap: ^Heap, cell: ^abi.Cell_Header) {
	if .Marked in cell.flags {
		return
	}
	cell.flags += {.Marked}
	gray(heap, cell)
}

@(private = "file")
gray :: proc(heap: ^Heap, cell: ^abi.Cell_Header) {
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
		cell := marks.cells[marks.count]
		cell.flags -= {.Remembered}
		scan_cell(heap, cell)
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
		case .Ref,
		     .Tagged,
		     .Ref_Or_Null,
		     .Ref_Or_Undefined,
		     .Any_Ref,
		     .Any_Ref_Or_Null,
		     .Any_Ref_Or_Undefined:
		}
		slots := ([^]byte)(array.elements)
		for i in 0 ..< array.length {
			mark_slot(heap, &slots[i * abi.ELEMENT_SIZE[table.element]], table.element)
		}
	}
}

// sweep walks pages and slots from the top down, so pushing each free slot leaves every list in
// address order, as carve_page makes it. It leaves the marks on.
@(private = "file")
sweep :: proc(heap: ^Heap, whole: bool) {
	heap.free = {}
	heap.used = 0
	for index := heap.page_count - 1; index >= 0; index -= 1 {
		page := heap.pages[index]
		#partial switch page.kind {
		case .Small:
			if page.full && !whole {
				size := abi.CLASS_SIZE[page.class]
				heap.used += PAGE_SIZE / size * size
			} else {
				sweep_page(heap, index)
			}
		case .Large:
			if .Marked in (^abi.Cell_Header)(&heap.base[index * PAGE_SIZE]).flags {
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
	slots := PAGE_SIZE / size
	for slot := slots - 1; slot >= 0; slot -= 1 {
		cell := (^abi.Cell_Header)(&page[slot * size])
		if cell.type_table != FREE {
			if .Marked in cell.flags {
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
	heap.pages[index].full = live == slots
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
