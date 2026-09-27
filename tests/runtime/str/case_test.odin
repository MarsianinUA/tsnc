package str_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

// One string of every code point but the surrogates, in order: 1,112,064 of them, 2,160,640 units.
// Its case forms are checked by length and by FNV-1a over their units, one unit per step, against
// what Node computes for the same string:
//
//	node -e 'let s = ""; for (let c = 0; c <= 0x10ffff; c++) if (c < 0xd800 || c > 0xdfff) s += String.fromCodePoint(c); const h = t => { let x = 0x811c9dc5; for (let i = 0; i < t.length; i++) x = Math.imul(x ^ t.charCodeAt(i), 16777619) >>> 0; return x.toString(16) }; console.log(s.length, h(s), s.toUpperCase().length, h(s.toUpperCase()), s.toLowerCase().length, h(s.toLowerCase()))'
@(test)
every_code_point_maps_as_node_maps_it :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	map_every_code_point(t, &heap)
}

// Collections run in here: the three strings are some four megabytes each, over gc.MIN_TRIGGER.
@(private = "file")
map_every_code_point :: #force_no_inline proc(t: ^testing.T, heap: ^gc.Heap) {
	units := make([dynamic]u16, 0, 2_160_640)
	defer delete(units)
	for r in rune(0) ..= 0x10ffff {
		switch {
		case r < 0xd800 || (0xe000 <= r && r <= 0xffff):
			append(&units, u16(r))
		case r > 0xffff:
			offset := r - 0x10000
			append(&units, u16(0xd800 + (offset >> 10)), u16(0xdc00 + (offset & 0x3ff)))
		}
	}
	text := cell(heap, units[:])
	expect_hash(t, text, 2_160_640, 0x0d0765c5)
	expect_hash(t, str.to_upper(heap, text), 2_160_758, 0x8b2cec51)
	expect_hash(t, str.to_lower(heap, text), 2_160_641, 0xa435fec7)
}

@(private = "file")
expect_hash :: proc(
	t: ^testing.T,
	text: ^abi.String_Cell,
	length: int,
	hash: u32,
	loc := #caller_location,
) {
	h := u32(0x811c9dc5)
	for unit in raw_data(str.units(text))[:text.length] {
		h = (h ~ u32(unit)) * 16777619
	}
	testing.expect_value(t, text.length, length, loc = loc)
	testing.expectf(t, h == hash, "FNV-1a %8x, want %8x", h, hash, loc = loc)
}
