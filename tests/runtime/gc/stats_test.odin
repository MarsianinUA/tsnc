package gc_tests

import "core:strings"
import "core:testing"
import "core:time"

import "../../../src/abi"
import "../../../src/runtime/gc"

@(test)
stats_count_every_allocation_and_collection :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	for _ in 0 ..< 3 {
		gc.alloc(&heap, POINT, POINT_SIZE)
	}
	gc.alloc(&heap, BLOB, 2 * gc.PAGE_SIZE + 1)
	point := abi.CLASS_SIZE[POINT_CLASS]
	allocated := 3 * point + 3 * gc.PAGE_SIZE
	testing.expect_value(t, heap.cells, 4)
	testing.expect_value(t, handed_out(&heap), allocated)
	testing.expect_value(t, heap.stats.collections, 0)

	collect_holding_a_point(t, &heap)
	stats := heap.stats
	testing.expect_value(t, stats.collections, 1)
	testing.expect_value(t, heap.cells, 5)
	testing.expect_value(t, handed_out(&heap), allocated + point)
	// The scan is conservative, so a stale word may keep more than the point.
	testing.expect_value(t, stats.live, heap.used)
	testing.expect(t, stats.live >= point)
	testing.expect_value(t, stats.longest, stats.marking + stats.sweeping)

	gc.collect(&heap)
	testing.expect_value(t, heap.stats.collections, 2)
	testing.expect_value(t, handed_out(&heap), allocated + point)
	testing.expect_value(t, heap.stats.live, heap.used)
}

// handed_out is the allocated figure of the stats line.
handed_out :: proc(heap: ^gc.Heap) -> int {
	return heap.stats.allocated + heap.used - heap.stats.live
}

// The point lies in this frame, below the heap, where the scan looks.
collect_holding_a_point :: proc(t: ^testing.T, heap: ^gc.Heap) {
	point := gc.alloc(heap, POINT, POINT_SIZE)
	gc.collect(heap)
	testing.expect_value(t, point.type_table, POINT)
}

@(test)
the_stats_line_reads_in_milliseconds_and_megabytes :: proc(t: ^testing.T) {
	heap := gc.Heap {
		head = {cells = 29_447_519, used = 11_200_000},
		page_count = 373,
		stats = {
			collections = 109,
			marking = 293_549 * time.Microsecond,
			sweeping = 190 * time.Microsecond,
			longest = 5_400 * time.Microsecond,
			live = 11_200_000,
			allocated = 942_344_765,
		},
	}
	b := strings.builder_make(context.temp_allocator)
	err := gc.write_stats(strings.to_writer(&b), &heap)
	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		strings.to_string(b),
		"gc: 109 collections, 293.5 ms marking, 0.1 ms sweeping, 5.4 ms longest pause, " +
		"29447519 cells, 898.6 MB allocated, 10.6 MB live, 23.3 MB heap\n",
	)
}
