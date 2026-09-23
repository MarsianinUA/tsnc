package arr_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Every expected value came out of Node 24; each test names the expressions. The tests of this file
stay below gc.MIN_TRIGGER, so no collection runs and their cells may live in the test procedure;
collect_test.odin runs the same procedures in stress mode.
*/

NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

RESERVE :: 64 * gc.PAGE_SIZE

// The program tables TABLES registers, numbered after the builtin ones: one array table per element
// kind, as lower makes them, and a cell of each other kind an element can point at.
NUMBERS :: abi.Type_Table_ID(len(abi.Builtin_Table))
BOOLEANS :: NUMBERS + 1
REFS :: NUMBERS + 2
VALUES :: NUMBERS + 3
POINT :: NUMBERS + 4
PRINTABLE :: NUMBERS + 5
CLOSURE :: NUMBERS + 6

TABLES := []abi.Type_Table {
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Number},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Boolean},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Ref},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Tagged},
	{kind = .Object, size = 16, fields = {{name = "x", offset = 8, kind = .Number}}},
	{kind = .Object, size = 16, fields = {{name = "toString", offset = 8, kind = .Ref}}},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
}

@(test)
push_grows_the_buffer_and_keeps_the_order :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	array := arr.new_array(&heap, NUMBERS, 0)
	testing.expect_value(t, array.capacity, 0)
	testing.expect(t, array.elements == nil, "an empty array with a buffer")

	for i in 0 ..< 1000 {
		testing.expect_value(t, arr.push(&heap, array, number(f64(i))), i + 1)
	}
	testing.expect_value(t, array.length, 1000)
	testing.expect(t, array.capacity >= 1000, "room for every element")
	for i in 0 ..< 1000 {
		expect_tagged(t, arr.element_at(&heap, array, i), number(f64(i)))
	}
	problem, _ := gc.verify(&heap)
	testing.expect_value(t, problem, gc.Heap_Problem.None)
}

// const p = [1, 2]; console.log(p.push(3), p.pop(), p.pop(), p.pop(), p.pop(), p.length)
@(test)
pop_takes_from_the_end_and_answers_undefined_when_empty :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	p := numbers(&heap, 1, 2)
	testing.expect_value(t, arr.push(&heap, p, number(3)), 3)
	expect_tagged(t, arr.pop(&heap, p), number(3))
	expect_tagged(t, arr.pop(&heap, p), number(2))
	expect_tagged(t, arr.pop(&heap, p), number(1))
	expect_tagged(t, arr.pop(&heap, p), abi.Tagged{})
	testing.expect_value(t, p.length, 0)
}

// An element leaves the array as a tagged value whose tag is what typeof would say of it.
@(test)
an_element_takes_the_tag_of_its_value :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	word := str.from_utf8(&heap, "a")
	point := gc.alloc(&heap, POINT, 16)
	inner := arr.new_array(&heap, NUMBERS, 0)
	closure := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))
	refs := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, refs, text(word))
	arr.push(&heap, refs, object(point))
	arr.push(&heap, refs, object(inner))
	arr.push(&heap, refs, function(closure))
	expect_tagged(t, arr.element_at(&heap, refs, 0), text(word))
	expect_tagged(t, arr.element_at(&heap, refs, 1), object(point))
	expect_tagged(t, arr.element_at(&heap, refs, 2), object(inner))
	expect_tagged(t, arr.pop(&heap, refs), function(closure))

	flags := arr.new_array(&heap, BOOLEANS, 0)
	arr.push(&heap, flags, boolean(true))
	expect_tagged(t, arr.pop(&heap, flags), boolean(true))

	values := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, values, null())
	arr.push(&heap, values, abi.Tagged{})
	expect_tagged(t, arr.element_at(&heap, values, 0), null())
	expect_tagged(t, arr.element_at(&heap, values, 1), abi.Tagged{})
}

// const a = [10, 20, 30, 40, 50]; for (const [s, e] of cases) console.log(a.slice(s, e))
@(test)
slice_copies_into_a_new_array :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	a := numbers(&heap, 10, 20, 30, 40, 50)
	cases := [?]struct {
		start, end: f64,
		want:       []f64,
	} {
		{0, INF, {10, 20, 30, 40, 50}},
		{1, 3, {20, 30}},
		{-2, INF, {40, 50}},
		{NAN, 2, {10, 20}},
		{2, INF, {30, 40, 50}},
		{3, 1, {}},
		{-10, -4, {10}},
		{0, NEGATIVE_ZERO, {}},
	}
	for c in cases {
		part := arr.slice(&heap, a, c.start, c.end)
		testing.expectf(t, part != a, "slice(%v, %v) answered the array itself", c.start, c.end)
		expect_numbers(t, &heap, part, c.want)
		if len(c.want) == 0 {
			testing.expect_value(t, part.capacity, 0)
		}
	}
	expect_numbers(t, &heap, a, {10, 20, 30, 40, 50})
}

//	const a = [10, 20, 30, 40, 50];
//	for (const f of cases) console.log(a.indexOf(40, f), a.includes(40, f))
@(test)
the_search_starts_where_node_starts_it :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	a := numbers(&heap, 10, 20, 30, 40, 50)
	cases := [?]struct {
		from:  f64,
		index: int,
	}{{0, 3}, {2, 3}, {-1, -1}, {-10, 3}, {10, -1}, {NAN, 3}, {-INF, 3}, {INF, -1}}
	for c in cases {
		testing.expectf(
			t,
			arr.index_of(&heap, a, number(40), c.from) == c.index,
			"indexOf(40, %v): want %d",
			c.from,
			c.index,
		)
		found := arr.includes(&heap, a, number(40), c.from)
		testing.expectf(t, found == (c.index != -1), "includes(40, %v)", c.from)
	}
}

//	[NaN, 1].indexOf(NaN), [NaN, 1].includes(NaN), [1, -0].indexOf(0), [1, 0].includes(-0)
//	["ab", "cd"].indexOf("c" + "d"), [1, "1"].indexOf("1"), [true, false].indexOf(false)
//	[undefined, null].indexOf(null), [undefined, null].indexOf(undefined), [NaN, undefined].includes(NaN)
@(test)
search_compares_as_node_does :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	with_nan := numbers(&heap, NAN, 1)
	testing.expect_value(t, arr.index_of(&heap, with_nan, number(NAN), 0), -1)
	testing.expect(t, arr.includes(&heap, with_nan, number(NAN), 0), "includes finds NaN")
	testing.expect_value(t, arr.index_of(&heap, numbers(&heap, 1, NEGATIVE_ZERO), number(0), 0), 1)
	testing.expect(
		t,
		arr.includes(&heap, numbers(&heap, 1, 0), number(NEGATIVE_ZERO), 0),
		"-0 finds 0",
	)

	// Strings by content: the search is a cell of its own.
	words := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, words, text(str.from_utf8(&heap, "ab")))
	arr.push(&heap, words, text(str.from_utf8(&heap, "cd")))
	testing.expect_value(t, arr.index_of(&heap, words, text(str.from_utf8(&heap, "cd")), 0), 1)

	// Objects by address.
	point := gc.alloc(&heap, POINT, 16)
	twin := gc.alloc(&heap, POINT, 16)
	points := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, points, object(point))
	testing.expect_value(t, arr.index_of(&heap, points, object(twin), 0), -1)
	testing.expect_value(t, arr.index_of(&heap, points, object(point), 0), 0)

	mixed := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, mixed, number(1))
	arr.push(&heap, mixed, text(str.from_utf8(&heap, "1")))
	testing.expect_value(t, arr.index_of(&heap, mixed, text(str.from_utf8(&heap, "1")), 0), 1)

	flags := arr.new_array(&heap, BOOLEANS, 0)
	arr.push(&heap, flags, boolean(true))
	arr.push(&heap, flags, boolean(false))
	testing.expect_value(t, arr.index_of(&heap, flags, boolean(false), 0), 1)

	empty := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, empty, abi.Tagged{})
	arr.push(&heap, empty, null())
	testing.expect_value(t, arr.index_of(&heap, empty, null(), 0), 1)
	testing.expect_value(t, arr.index_of(&heap, empty, abi.Tagged{}, 0), 0)

	nan_first := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, nan_first, number(NAN))
	arr.push(&heap, nan_first, abi.Tagged{})
	testing.expect(t, arr.includes(&heap, nan_first, number(NAN), 0), "a tagged NaN finds NaN")
}

// s.split(separator, limit), each piece as its units in hex
@(test)
split_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	cases := [?]struct {
		text, separator: []u16,
		limit:           f64,
		want:            [][]u16,
	} {
		{{}, {','}, abi.MISSING_LIMIT, {{}}},
		{{}, {}, abi.MISSING_LIMIT, {}},
		{{'a', ',', 'b', ',', ',', 'c'}, {','}, abi.MISSING_LIMIT, {{'a'}, {'b'}, {}, {'c'}}},
		{{'a', ',', 'b', ',', ',', 'c'}, {','}, 2, {{'a'}, {'b'}}},
		{{'a', ',', 'b', ',', ',', 'c'}, {','}, 0, {}},
		{{'a', ',', 'b'}, {','}, -1, {{'a'}, {'b'}}},
		{{'a', 'b', 'c'}, {}, abi.MISSING_LIMIT, {{'a'}, {'b'}, {'c'}}},
		{{'a', 'b'}, {'a', 'b', 'c'}, abi.MISSING_LIMIT, {{'a', 'b'}}},
		{{',', 'a', ','}, {','}, abi.MISSING_LIMIT, {{}, {'a'}, {}}},
		{{'a', '-', '-', 'b', '-', '-'}, {'-', '-'}, abi.MISSING_LIMIT, {{'a'}, {'b'}, {}}},
		// An emoji splits into its two surrogates.
		{{0xd83d, 0xde00, 'x'}, {}, abi.MISSING_LIMIT, {{0xd83d}, {0xde00}, {'x'}}},
	}
	for c in cases {
		text := str.from_units(&heap, string16(c.text))
		separator := str.from_units(&heap, string16(c.separator))
		pieces := arr.split(&heap, text, separator, c.limit)
		testing.expect_value(t, pieces.type_table, REFS)
		if !testing.expectf(
			t,
			pieces.length == len(c.want),
			"%x split by %x: %d pieces",
			c.text,
			c.separator,
			pieces.length,
		) {
			continue
		}
		if len(c.want) == 0 {
			testing.expect_value(t, pieces.capacity, 0)
		}
		for want, i in c.want {
			piece := arr.element_at(&heap, pieces, i)
			testing.expect_value(t, piece.tag, abi.Tag.String)
			expect_units(t, (^abi.String_Cell)(piece.payload.ref), want)
		}
	}
}

// init_heap makes `heap`, a local of the test procedure, the heap under test and the base of its
// stack scan, as tests/runtime/gc does.
init_heap :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	mode := gc.Heap_Mode.Normal,
	loc := #caller_location,
) {
	err := gc.heap_init(heap, TABLES, nil, heap, mode, RESERVE)
	testing.expect_value(t, err, gc.Heap_Error.None, loc = loc)
}

numbers :: proc(heap: ^gc.Heap, values: ..f64) -> ^abi.Array_Cell {
	array := arr.new_array(heap, NUMBERS, 0)
	for n in values {
		arr.push(heap, array, number(n))
	}
	return array
}

null :: proc() -> abi.Tagged {
	return {tag = .Null}
}

boolean :: proc(b: bool) -> abi.Tagged {
	return {tag = .Boolean, payload = {boolean = b64(b)}}
}

number :: proc(n: f64) -> abi.Tagged {
	return {tag = .Number, payload = {number = n}}
}

text :: proc(cell: ^abi.String_Cell) -> abi.Tagged {
	return {tag = .String, payload = {ref = cell}}
}

object :: proc(cell: ^abi.Cell_Header) -> abi.Tagged {
	return {tag = .Object, payload = {ref = cell}}
}

function :: proc(cell: ^abi.Cell_Header) -> abi.Tagged {
	return {tag = .Function, payload = {ref = cell}}
}

// expect_tagged compares the two words, so NaN matches NaN and the two zeros differ. abi.Tagged holds
// a raw union, which Odin does not compare.
expect_tagged :: proc(t: ^testing.T, got, want: abi.Tagged, loc := #caller_location) {
	testing.expectf(
		t,
		transmute([2]u64)got == transmute([2]u64)want,
		"got %v %x, want %v %x",
		got.tag,
		transmute(u64)got.payload,
		want.tag,
		transmute(u64)want.payload,
		loc = loc,
	)
}

// expect_numbers compares bits, so NaN matches NaN and the two zeros differ.
expect_numbers :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	want: []f64,
	loc := #caller_location,
) {
	if !testing.expectf(
		t,
		array.length == len(want),
		"length %d, want %v",
		array.length,
		want,
		loc = loc,
	) {
		return
	}
	for n, i in want {
		expect_tagged(t, arr.element_at(heap, array, i), number(n), loc = loc)
	}
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
