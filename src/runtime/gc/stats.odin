package gc

import "core:io"
import "core:time"

// write_stats writes the line of TSNC_GC_STATS (docs/development.md#gc-statistics). bench/runner
// reads its fields by position, so the order stays. A megabyte is 2^20 bytes, and a tenth is cut,
// not rounded.
write_stats :: proc(w: io.Writer, heap: ^Heap) -> io.Error {
	stats := heap.stats
	io.write_string(w, "gc: ") or_return
	write_count(w, stats.collections, " collections, ") or_return
	write_milliseconds(w, stats.marking, " ms marking, ") or_return
	write_milliseconds(w, stats.sweeping, " ms sweeping, ") or_return
	write_milliseconds(w, stats.longest, " ms longest pause, ") or_return
	write_count(w, heap.cells, " cells, ") or_return
	write_megabytes(w, heap.allocated, " MB allocated, ") or_return
	write_megabytes(w, stats.live, " MB live, ") or_return
	write_megabytes(w, heap.page_count * PAGE_SIZE, " MB heap\n") or_return
	return nil
}

@(private = "file")
write_count :: proc(w: io.Writer, count: int, unit: string) -> io.Error {
	io.write_int(w, count) or_return
	io.write_string(w, unit) or_return
	return nil
}

@(private = "file")
write_milliseconds :: proc(w: io.Writer, duration: time.Duration, unit: string) -> io.Error {
	return write_tenths(w, int(duration / (100 * time.Microsecond)), unit)
}

@(private = "file")
write_megabytes :: proc(w: io.Writer, bytes: int, unit: string) -> io.Error {
	return write_tenths(w, bytes * 10 / (1 << 20), unit)
}

@(private = "file")
write_tenths :: proc(w: io.Writer, tenths: int, unit: string) -> io.Error {
	io.write_int(w, tenths / 10) or_return
	io.write_byte(w, '.') or_return
	io.write_int(w, tenths % 10) or_return
	io.write_string(w, unit) or_return
	return nil
}
