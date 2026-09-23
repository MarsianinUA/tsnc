package str_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

// toUpperCase and toLowerCase of one string each, from Node 24 (Unicode 17.0), for example:
//
//	node -e 'const s = String.fromCharCode(0xdf); console.log([...s.toUpperCase()].map(c => c.charCodeAt(0).toString(16)))'
@(test)
case_corners_match_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	// The first row is "Privet" in Cyrillic.
	cases := [?]struct {
		text, upper, lower: []u16,
	} {
		{
			{0x041f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442},
			{0x041f, 0x0420, 0x0418, 0x0412, 0x0415, 0x0422},
			{0x043f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442},
		},
		// Full mappings that expand: sharp s, the ffi ligature, n preceded by an apostrophe, and
		// the Greek iota with dialytika and tonos.
		{{0x00df}, {0x0053, 0x0053}, {0x00df}},
		{{0xfb03}, {0x0046, 0x0046, 0x0049}, {0xfb03}},
		{{0x0149}, {0x02bc, 0x004e}, {0x0149}},
		{{0x0390}, {0x0399, 0x0308, 0x0301}, {0x0390}},
		// The one lowercase expansion: capital I with dot above.
		{{0x0130}, {0x0130}, {0x0069, 0x0307}},
		// Capital sharp s has a simple lowercase only.
		{{0x1e9e}, {0x1e9e}, {0x00df}},
		// Alpha with prosgegrammeni, and its small form: both upper to two letters.
		{{0x1fbc}, {0x0391, 0x0399}, {0x1fb3}},
		{{0x1fb3}, {0x0391, 0x0399}, {0x1fb3}},
		// The titlecase digraph Dz with caron goes both ways.
		{{0x01c5}, {0x01c4}, {0x01c6}},
		// Combining ypogegrammeni uppers to a capital iota.
		{{0x0345}, {0x0399}, {0x0345}},
		// Georgian Mkhedruli uppers to Mtavruli (Unicode 11), which lowers back.
		{{0x10d0}, {0x1c90}, {0x10d0}},
		{{0x1c90}, {0x1c90}, {0x10d0}},
		// Cherokee: the capitals lower to the small letters of Unicode 8.
		{{0x13a0}, {0x13a0}, {0xab70}},
		{{0xab70}, {0x13a0}, {0xab70}},
		{{0x13f8}, {0x13f0}, {0x13f8}},
		// Deseret, outside the BMP, both ways.
		{{0xd801, 0xdc00}, {0xd801, 0xdc00}, {0xd801, 0xdc28}},
		{{0xd801, 0xdc28}, {0xd801, 0xdc00}, {0xd801, 0xdc28}},
		// Lone surrogates stay as they are, and so does an emoji.
		{{'a', 0xd800, 'b', 0xdc00}, {'A', 0xd800, 'B', 0xdc00}, {'a', 0xd800, 'b', 0xdc00}},
	}
	for c in cases {
		text := cell(&heap, c.text)
		expect_units(t, str.to_upper(&heap, text), c.upper)
		expect_units(t, str.to_lower(&heap, text), c.lower)
	}

	ascii := str.from_utf8(&heap, "Hello, World! 123")
	expect_ascii(t, str.to_upper(&heap, ascii), "HELLO, WORLD! 123")
	expect_ascii(t, str.to_lower(&heap, ascii), "hello, world! 123")

	// A string the mapping leaves alone is answered as it is, a special row that maps a letter to
	// itself included.
	emoji := cell(&heap, {0xd83d, 0xde00, '1'})
	testing.expect_value(t, str.to_upper(&heap, emoji), emoji)
	testing.expect_value(t, str.to_lower(&heap, emoji), emoji)
	ligatures := cell(&heap, {0x00df, 0xfb03, 0x0149})
	testing.expect_value(t, str.to_lower(&heap, ligatures), ligatures)
	dotted := cell(&heap, {0x0130})
	testing.expect_value(t, str.to_upper(&heap, dotted), dotted)
}

// Final_Sigma: a capital sigma lowers to the final form when a cased letter comes before it and none
// after it, with case-ignorable code points skipped on both sides.
@(test)
final_sigma_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	ALPHA :: 0x0391
	SIGMA :: 0x03a3
	SMALL_ALPHA :: 0x03b1
	SMALL_SIGMA :: 0x03c3
	FINAL_SIGMA :: 0x03c2
	cases := [?]struct {
		text, lower: []u16,
	} {
		{{ALPHA, SIGMA}, {SMALL_ALPHA, FINAL_SIGMA}},
		{{ALPHA, SIGMA, ' ', ALPHA}, {SMALL_ALPHA, FINAL_SIGMA, ' ', SMALL_ALPHA}},
		{{SIGMA}, {SMALL_SIGMA}},
		{{ALPHA, SIGMA, '.'}, {SMALL_ALPHA, FINAL_SIGMA, '.'}},
		// The full stop is case-ignorable, so the alpha before it still counts.
		{{ALPHA, '.', SIGMA}, {SMALL_ALPHA, '.', FINAL_SIGMA}},
		// U+0345 and U+02B0 are both cased and case-ignorable, and ignorable wins: no cased letter
		// before the sigma, and the alpha after it still counts.
		{{0x0345, SIGMA}, {0x0345, SMALL_SIGMA}},
		{{0x02b0, SIGMA}, {0x02b0, SMALL_SIGMA}},
		{{ALPHA, SIGMA, 0x0345, ALPHA}, {SMALL_ALPHA, SMALL_SIGMA, 0x0345, SMALL_ALPHA}},
		// U+00AA is cased and not case-ignorable.
		{{0x00aa, SIGMA}, {0x00aa, FINAL_SIGMA}},
		{{ALPHA, SIGMA, SIGMA}, {SMALL_ALPHA, SMALL_SIGMA, FINAL_SIGMA}},
		// A lone surrogate is neither, so it breaks the context on either side.
		{{ALPHA, 0xd800, SIGMA}, {SMALL_ALPHA, 0xd800, SMALL_SIGMA}},
		{{ALPHA, SIGMA, 0xdc00, ALPHA}, {SMALL_ALPHA, FINAL_SIGMA, 0xdc00, SMALL_ALPHA}},
		// Deseret capital long I, a cased letter outside the BMP, lowers too.
		{{0xd801, 0xdc00, SIGMA}, {0xd801, 0xdc28, FINAL_SIGMA}},
	}
	for c in cases {
		expect_units(t, str.to_lower(&heap, cell(&heap, c.text)), c.lower)
	}
}

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
