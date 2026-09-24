package str_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Every expected value came out of Node 24, spelled as UTF-16 units in hex so that no case trusts the
encoder it checks. Regenerate a row with, for example:

	node -e 'const s = "a" + String.fromCodePoint(0x1f600); console.log([...s.slice(1, 2)].map(c => c.charCodeAt(0).toString(16)))'

The tests of this file stay far below gc.MIN_TRIGGER, so no collection runs and their cells may
live in the test procedure. collect_test.odin is where every allocation collects.
*/

NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

// RESERVE holds the largest test, the case mapping of every code point: three strings of some
// four megabytes each, and the cells a collection has not freed yet.
RESERVE :: 1024 * gc.PAGE_SIZE

// "a", U+1F600 as a surrogate pair, then "Privet" in Cyrillic.
@(rodata)
MIXED := [?]u16{0x0061, 0xd83d, 0xde00, 0x041f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442}

@(test)
from_utf8_counts_utf16_units :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	privet := str.from_utf8(&heap, "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82")
	expect_units(t, privet, {0x041f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442})
	expect_units(t, str.from_utf8(&heap, "\U0001F600"), {0xd83d, 0xde00})
	expect_units(t, str.from_utf8(&heap, "a\U0001F600\xd0\xb1"), {0x0061, 0xd83d, 0xde00, 0x0431})
	expect_units(t, str.from_utf8(&heap, "a\xffb"), {0x0061, 0xfffd, 0x0062})
	expect_units(t, str.from_units(&heap, string16(MIXED[:])), MIXED[:])
}

// Buffer.toString replaces each maximal subpart of an ill-formed sequence with one U+FFFD, and so
// does from_utf8. The first row is the example of Unicode 17, section 3.9.
//
//	node -e 'console.log([...Buffer.from([0x61, 0xe2, 0x82, 0x62]).toString()].map(c => c.codePointAt(0).toString(16)))'
@(test)
from_utf8_repairs_bytes_as_node_does :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	cases := [?]struct {
		bytes: string,
		units: []u16,
	} {
		{
			"\x61\xf1\x80\x80\xe1\x80\xc2\x62\x80\x63\x80\xbf\x64",
			{0x61, 0xfffd, 0xfffd, 0xfffd, 0x62, 0xfffd, 0x63, 0xfffd, 0xfffd, 0x64},
		},
		{"a\xe2\x82b", {0x61, 0xfffd, 0x62}},
		// A byte order mark stays.
		{"\xef\xbb\xbfA", {0xfeff, 0x41}},
		// A surrogate, an overlong form and a code point past U+10FFFF: no two bytes of these start
		// a well-formed sequence, so each byte is a subpart of its own.
		{"\xed\xa0\x80", {0xfffd, 0xfffd, 0xfffd}},
		{"\xc0\x80", {0xfffd, 0xfffd}},
		{"\xe0\x9f\x80", {0xfffd, 0xfffd, 0xfffd}},
		{"\xf4\x90\x80\x80", {0xfffd, 0xfffd, 0xfffd, 0xfffd}},
		{"\xf8\x88\x80\x80\x80", {0xfffd, 0xfffd, 0xfffd, 0xfffd, 0xfffd}},
		// A sequence cut short by the end of the text.
		{"a\xf0\x9f\x98", {0x61, 0xfffd}},
		{"\xf0\x9f\x98\x80", {0xd83d, 0xde00}},
	}
	for c in cases {
		expect_units(t, str.from_utf8(&heap, c.bytes), c.units)
	}
}

// 536,870,888 units is the longest string Node 24 builds:
//
//	node -e 'console.log("a".repeat(536870888).length); "a".repeat(536870889)'
//
// prints the length, then throws "RangeError: Invalid string length".
@(test)
a_string_is_as_long_as_node_allows :: proc(t: ^testing.T) {
	testing.expect_value(t, str.MAX_LENGTH, 536_870_888)
	testing.expect(t, str.length_fits(str.MAX_LENGTH))
	testing.expect(t, !str.length_fits(str.MAX_LENGTH + 1))
}

@(test)
the_empty_string_is_one_static_cell :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	empty := str.from_utf8(&heap, "")
	testing.expect_value(t, empty.length, 0)
	testing.expect_value(t, empty.type_table, abi.Type_Table_ID(abi.Builtin_Table.String))
	testing.expect(t, gc.owner(&heap, empty) == nil, "the empty string is a heap cell")
	testing.expect_value(t, str.from_units(&heap, ""), empty)

	text := str.from_utf8(&heap, "abc")
	testing.expect_value(t, str.slice(&heap, text, 2, 1), empty)
	testing.expect_value(t, str.trim(&heap, str.from_utf8(&heap, " \t\n")), empty)
	// Two slots of 32 bytes, "abc" and the whitespace: no empty result took one.
	testing.expect_value(t, heap.used, 2 * 32)
}

@(test)
concat_joins_units :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	privet := cell(&heap, MIXED[3:])
	emoji := cell(&heap, MIXED[1:3])
	expect_units(
		t,
		str.concat(&heap, privet, emoji),
		{0x041f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442, 0xd83d, 0xde00},
	)

	// The two halves of a surrogate pair, each a string of its own, make the pair.
	pair := str.concat(&heap, cell(&heap, {0xd83d}), cell(&heap, {0xde00}))
	expect_units(t, pair, {0xd83d, 0xde00})

	empty := str.from_utf8(&heap, "")
	testing.expect_value(t, str.concat(&heap, empty, privet), privet)
	testing.expect_value(t, str.concat(&heap, privet, empty), privet)
}

@(test)
equality_and_order_go_by_units :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	a, b := cell(&heap, MIXED[:]), cell(&heap, MIXED[:])
	testing.expect(t, a != b && str.equal(a, b), "equal content in two cells")
	testing.expect(t, !str.equal(a, cell(&heap, MIXED[:8])), "a prefix")
	testing.expect(t, str.compare(a, b) == 0, "equal content orders equal")

	// U+0100 > U+00FF, while their bytes on a little-endian machine order the other way.
	testing.expect(t, str.compare(cell(&heap, {0x0100}), cell(&heap, {0x00ff})) > 0, "U+0100")
	// U+1F600 < U+FFFF, and U+FFFF < U+10000 is false: units, not code points.
	emoji, last_bmp := cell(&heap, {0xd83d, 0xde00}), cell(&heap, {0xffff})
	testing.expect(t, str.compare(emoji, last_bmp) < 0, "U+1F600 against U+FFFF")
	testing.expect(t, str.compare(last_bmp, cell(&heap, {0xd800, 0xdc00})) > 0, "U+FFFF")
	prefix, longer := str.from_utf8(&heap, "ab"), str.from_utf8(&heap, "abc")
	testing.expect(t, str.compare(prefix, longer) < 0, "a prefix orders first")
}

// "a\u{1F600}Privet".charCodeAt(position)
@(test)
char_code_at_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	text := cell(&heap, MIXED[:])
	cases := [?]struct {
		position: f64,
		code:     f64,
	} {
		{0, 97},
		{1, 55357},
		{2, 56832},
		{3, 1055},
		{8, 1090},
		// ToIntegerOrInfinity: a fraction goes toward zero and NaN is 0.
		{-0.5, 97},
		{-1e-300, 97},
		{NAN, 97},
		{2.9, 56832},
		{9, NAN},
		{-1, NAN},
		{INF, NAN},
		{-INF, NAN},
	}
	for c in cases {
		got := str.char_code_at(text, c.position)
		same := got == c.code || (got != got && c.code != c.code)
		testing.expectf(t, same, "charCodeAt(%v): got %v, want %v", c.position, got, c.code)
	}
}

// "a\u{1F600}Privet".slice(start, end), with +Infinity for a missing end
@(test)
slice_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	text := cell(&heap, MIXED[:])
	cases := [?]struct {
		start, end: f64,
		units:      []u16,
	} {
		{-3, INF, {0x0432, 0x0435, 0x0442}},
		{-1.9, INF, {0x0442}},
		{1.9, 3, {0xd83d, 0xde00}},
		{NAN, 2, {0x0061, 0xd83d}},
		{1, 2, {0xd83d}},
		{2, 3, {0xde00}},
		{0, NAN, {}},
		{3, 1, {}},
		{9, INF, {}},
	}
	for c in cases {
		expect_units(t, str.slice(&heap, text, c.start, c.end), c.units)
	}
	testing.expect_value(t, str.slice(&heap, text, -INF, INF), text)
	testing.expect_value(t, str.slice(&heap, text, 0, 9), text)
}

@(test)
unit_at_answers_one_unit :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	text := cell(&heap, MIXED[:])
	expect_units(t, str.unit_at(&heap, text, 1), {0xd83d})
	expect_units(t, str.unit_at(&heap, text, 3), {0x041f})
	expect_units(t, str.unit_at(&heap, text, NEGATIVE_ZERO), {0x0061})
}

// for (const c of "a" + String.fromCodePoint(0x1f600) + "\ud800b\udc00") takes a pair whole and a
// lone surrogate of either half by itself.
@(test)
code_point_at_answers_what_for_of_yields :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	text := cell(&heap, {0x0061, 0xd83d, 0xde00, 0xd800, 0x0062, 0xdc00})
	expect_units(t, str.code_point_at(&heap, text, 0), {0x0061})
	expect_units(t, str.code_point_at(&heap, text, 1), {0xd83d, 0xde00})
	expect_units(t, str.code_point_at(&heap, text, 2), {0xde00})
	expect_units(t, str.code_point_at(&heap, text, 3), {0xd800})
	expect_units(t, str.code_point_at(&heap, text, 4), {0x0062})
	expect_units(t, str.code_point_at(&heap, text, 5), {0xdc00})
	high_at_the_end := cell(&heap, {0x0061, 0xd83d})
	expect_units(t, str.code_point_at(&heap, high_at_the_end, 1), {0xd83d})
}

// "abc".indexOf(search, position) and the other two, 0 for a missing position and +Infinity for
// a missing end
@(test)
search_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	text := str.from_utf8(&heap, "abc")
	index_cases := [?]struct {
		search:   string,
		position: f64,
		index:    int,
	} {
		{"b", 0, 1},
		{"b", 2, -1},
		{"bc", 1.9, 1},
		{"abcd", 0, -1},
		{"c", INF, -1},
		{"c", -INF, 2},
		// An empty search is found where the position, clamped to the length, points.
		{"", 10, 3},
		{"", NAN, 0},
	}
	for c in index_cases {
		got := str.index_of(text, str.from_utf8(&heap, c.search), c.position)
		testing.expectf(t, got == c.index, "indexOf(%q, %v): got %d", c.search, c.position, got)
	}

	Edge_Case :: struct {
		search:   string,
		position: f64,
		answer:   bool,
	}
	starts := [?]Edge_Case {
		{"b", 1, true},
		{"c", 10, false},
		{"", 10, true},
		{"a", -5, true},
		{"abcd", 0, false},
	}
	for c in starts {
		got := str.starts_with(text, str.from_utf8(&heap, c.search), c.position)
		testing.expectf(
			t,
			got == c.answer,
			"startsWith(%q, %v): got %v",
			c.search,
			c.position,
			got,
		)
	}
	ends := [?]Edge_Case {
		{"b", 2, true},
		{"c", INF, true},
		{"c", 10, true},
		{"c", NAN, false},
		{"", NAN, true},
		{"abcd", INF, false},
	}
	for c in ends {
		got := str.ends_with(text, str.from_utf8(&heap, c.search), c.position)
		testing.expectf(t, got == c.answer, "endsWith(%q, %v): got %v", c.search, c.position, got)
	}
}

@(test)
trim_strips_the_whitespace_of_ecmascript :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	// U+FEFF, U+00A0, U+2028, U+3000 and ASCII whitespace before "x y", U+3000 and U+2029 after.
	padded := str.from_utf8(
		&heap,
		"\xef\xbb\xbf\xc2\xa0\xe2\x80\xa8\xe3\x80\x80 \t\n\v\f\rx y\xe3\x80\x80\xe2\x80\xa9",
	)
	expect_ascii(t, str.trim(&heap, padded), "x y")

	// U+0085 has the Unicode White_Space property and U+200B is a format character: neither is
	// whitespace to ECMAScript.
	kept := cell(&heap, {0x0085, 0x200b, 'x', 0x200b, 0x0085})
	testing.expect_value(t, str.trim(&heap, kept), kept)
}

// "text".split(separator, limit), with 4294967295 for a missing limit
@(test)
splitter_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	cases := [?]struct {
		text, separator: string,
		limit:           f64,
		pieces:          []string,
	} {
		{"", "", abi.MISSING_LIMIT, {}},
		{"", ",", abi.MISSING_LIMIT, {""}},
		{"aaa", "aa", abi.MISSING_LIMIT, {"", "a"}},
		{",a,,b,", ",", abi.MISSING_LIMIT, {"", "a", "", "b", ""}},
		{"abc", "", 2, {"a", "b"}},
		// ToUint32: a fraction goes toward zero, the rest wraps modulo 2^32, and NaN and the
		// infinities are 0.
		{"a,b,c", ",", 0, {}},
		{"a,b,c", ",", 1.9, {"a"}},
		{"a,b,c", ",", -1, {"a", "b", "c"}},
		{"a,b,c", ",", 4294967296, {}},
		{"a,b,c", ",", 4294967297, {"a"}},
		{"a,b,c", ",", INF, {}},
		{"a,b,c", ",", NAN, {}},
	}
	for c in cases {
		text, separator := str.from_utf8(&heap, c.text), str.from_utf8(&heap, c.separator)
		s := str.splitter(text, separator, c.limit)
		count := 0
		for piece in str.split_next(&s) {
			if count < len(c.pieces) {
				want := str.from_utf8(&heap, c.pieces[count])
				testing.expectf(
					t,
					piece == str.units(want),
					"%q by %q: piece %d",
					c.text,
					c.separator,
					count,
				)
			}
			count += 1
		}
		testing.expectf(
			t,
			count == len(c.pieces),
			"%q by %q: %d pieces",
			c.text,
			c.separator,
			count,
		)
	}

	// An empty separator splits a surrogate pair into its halves.
	emoji := cell(&heap, {0xd83d, 0xde00, 'x'})
	s := str.splitter(emoji, str.from_utf8(&heap, ""), abi.MISSING_LIMIT)
	for want in ([?]u16{0xd83d, 0xde00, 'x'}) {
		piece, ok := str.split_next(&s)
		testing.expect(t, ok && len(piece) == 1 && piece[0] == want, "a single unit")
	}
	_, more := str.split_next(&s)
	testing.expect(t, !more, "a piece past the end")
}

@(test)
numbers_meet_cells :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	expect_ascii(t, str.from_number(&heap, NEGATIVE_ZERO), "0")
	expect_ascii(t, str.from_number(&heap, 1e21), "1e+21")

	fixed, ok := str.to_fixed(&heap, 1.25, 1)
	testing.expect(t, ok, "(1.25).toFixed(1) failed")
	expect_ascii(t, fixed, "1.3")
	for c in ([?][2]f64{{1, 101}, {1, -1}, {NAN, 101}}) {
		_, in_range := str.to_fixed(&heap, c[0], c[1])
		testing.expectf(t, !in_range, "(%v).toFixed(%v) did not fail", c[0], c[1])
	}

	testing.expect_value(t, str.parse_float(str.from_utf8(&heap, "   3.5abc")), 3.5)
	// U+3000, U+FEFF, "-1.5e3", then an Arabic-Indic digit, which ends the numeral.
	arabic := cell(&heap, {0x3000, 0xfeff, '-', '1', '.', '5', 'e', '3', 0x0661})
	testing.expect_value(t, str.parse_float(arabic), -1500)
	testing.expect_value(t, str.parse_float(str.from_utf8(&heap, "-Infinityx")), -INF)
	for text in ([?][]u16{{0x0085, '3'}, {}}) {
		value := str.parse_float(cell(&heap, text))
		testing.expectf(t, value != value, "parseFloat(%x): got %v", text, value)
	}
}

init_heap :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	mode := gc.Heap_Mode.Normal,
	loc := #caller_location,
) {
	err := gc.heap_init(heap, nil, nil, heap, mode, RESERVE)
	testing.expect_value(t, err, gc.Heap_Error.None, loc = loc)
}

cell :: proc(heap: ^gc.Heap, units: []u16) -> ^abi.String_Cell {
	return str.from_units(heap, string16(units))
}

expect_units :: proc(t: ^testing.T, text: ^abi.String_Cell, want: []u16, loc := #caller_location) {
	got := str.units(text)
	testing.expectf(
		t,
		got == string16(want),
		"got %x, want %x",
		raw_data(got)[:len(got)],
		want,
		loc = loc,
	)
}

expect_ascii :: proc(
	t: ^testing.T,
	text: ^abi.String_Cell,
	want: string,
	loc := #caller_location,
) {
	got := str.units(text)
	same := len(got) == len(want)
	for i in 0 ..< min(len(got), len(want)) {
		same &&= got[i] == u16(want[i])
	}
	testing.expectf(t, same, "got %x, want %q", raw_data(got)[:len(got)], want, loc = loc)
}
