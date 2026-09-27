package str_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Text is spelled as UTF-16 units in hex, so that no case trusts the encoder it checks. What the
methods answer is pinned by the programs of tests/diff; the tests here check what no program can
see.

The tests of this file stay far below gc.MIN_TRIGGER, so no collection runs and their cells may
live in the test procedure. collect_test.odin is where every allocation collects.
*/

NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000

// RESERVE holds the largest test, the case mapping of every code point: three strings of some
// four megabytes each, and the cells a collection has not freed yet.
RESERVE :: 1024 * gc.PAGE_SIZE

// "a", U+1F600 as a surrogate pair, then "Privet" in Cyrillic.
@(rodata)
MIXED := [?]u16{0x0061, 0xd83d, 0xde00, 0x041f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442}

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

// A result that is one of the arguments whole comes back as that cell, not a copy: concat with an
// empty side, a slice of the whole, a trim or a case mapping that changes nothing.
@(test)
a_result_the_input_already_is_takes_no_cell :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	text := cell(&heap, MIXED[:])
	empty := str.from_utf8(&heap, "")
	testing.expect_value(t, str.concat(&heap, empty, text), text)
	testing.expect_value(t, str.concat(&heap, text, empty), text)
	testing.expect_value(t, str.slice(&heap, text, -INF, INF), text)
	testing.expect_value(t, str.slice(&heap, text, 0, 9), text)
	kept := cell(&heap, {0x0085, 0x200b, 'x', 0x200b, 0x0085})
	testing.expect_value(t, str.trim(&heap, kept), kept)

	// The ligatures and U+0130 map to themselves through a special row.
	emoji := cell(&heap, {0xd83d, 0xde00, '1'})
	testing.expect_value(t, str.to_upper(&heap, emoji), emoji)
	testing.expect_value(t, str.to_lower(&heap, emoji), emoji)
	ligatures := cell(&heap, {0x00df, 0xfb03, 0x0149})
	testing.expect_value(t, str.to_lower(&heap, ligatures), ligatures)
	dotted := cell(&heap, {0x0130})
	testing.expect_value(t, str.to_upper(&heap, dotted), dotted)
}

// A digit count out of range is num's refusal, which to_fixed passes on for the runtime to fail
// with.
@(test)
to_fixed_passes_a_refusal_on :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	for c in ([?][2]f64{{1, 101}, {1, -1}, {NAN, 101}}) {
		_, in_range := str.to_fixed(&heap, c[0], c[1])
		testing.expectf(t, !in_range, "(%v).toFixed(%v) did not fail", c[0], c[1])
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
