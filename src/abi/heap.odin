package abi

import "base:intrinsics"

// The size classes of the GC heap live here because generated code takes a small cell off the free
// list of its class itself (Heap_Head).

// MAX_SMALL is the largest cell a size class holds; a larger one takes whole pages of the heap.
MAX_SMALL :: 32 << 10
CLASS_COUNT :: 41

// CLASS_SIZE steps by 16 bytes up to 128, with 24 for a header and two words, then takes four
// classes per doubling, as Go's classes do, so a cell leaves at most a fifth of its slot unused.
// Every size is a multiple of 8, the alignment every slot needs, a Tagged included.
@(rodata)
CLASS_SIZE := [CLASS_COUNT]int {
	16,
	24,
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

// class_of reads the class off the layout of CLASS_SIZE: steps of 16 up to 128, then four classes
// for each power of two, told apart by the two bits below the top one of size - 1; the 24-byte
// class moves every class above it up by one.
class_of :: proc "contextless" (size: int) -> int {
	past_24 := 1 if size > 24 else 0
	if size <= 128 {
		return (size - 1) >> 4 + past_24
	}
	top := 63 - int(intrinsics.count_leading_zeros(u64(size - 1)))
	return 4 * top - 24 + ((size - 1) >> uint(top - 2)) + past_24
}

// Free_Slot is what a slot holds while it waits on the free list of its class; its header names a
// table only the collector knows. The smallest class is its size.
Free_Slot :: struct {
	header: Cell_Header,
	next:   ^Free_Slot,
}

// Heap_Head is the part of the GC heap generated code allocates from, through the pointer
// HEAP_SYMBOL hands it. A cell of `size` bytes, at most MAX_SMALL, takes the slot at
// free[class_of(size)] when there is one and used + CLASS_SIZE[class] stays within limit: free
// takes the slot's next, used grows by the class size and cells by one, then the first
// max(size, size_of(Free_Slot)) bytes are zeroed and the header names the table. Anything else
// goes to Runtime_Proc.Alloc, which may collect. The runtime keeps limit at 0 where every
// allocation has to reach it.
Heap_Head :: struct {
	free:  [CLASS_COUNT]^Free_Slot,
	used:  int, // bytes of the slots and runs that hold cells
	limit: int,
	cells: int,
}
