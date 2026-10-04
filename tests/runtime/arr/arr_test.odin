package arr_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
The tests of this file stay below gc.MIN_TRIGGER, so no collection runs and their cells may live in
the test procedure; collect_test.odin runs the same procedures in stress mode. What these procedures
answer is pinned by the programs of tests/diff; the tests here check what no program can see.
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
VALUE_OF :: NUMBERS + 7

TABLES := []abi.Type_Table {
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Number},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Boolean},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Ref},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Tagged},
	{kind = .Object, size = 16, fields = {{name = "x", offset = 8, kind = .Number}}},
	{kind = .Object, size = 16, fields = {{name = "toString", offset = 8, kind = .Ref}}},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
	{kind = .Object, size = 16, fields = {{name = "valueOf", offset = 8, kind = .Ref}}},
}

// An array literal and the result of map start at their final length, each element the zero of its
// kind; a Ref element is nil until generated code stores it.
@(test)
new_zeroed_has_its_length_and_zero_elements :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	numbers := arr.new_zeroed(&heap, NUMBERS, 3)
	booleans := arr.new_zeroed(&heap, BOOLEANS, 3)
	values := arr.new_zeroed(&heap, VALUES, 3)
	refs := arr.new_zeroed(&heap, REFS, 3)
	for i in 0 ..< 3 {
		expect_tagged(t, arr.element_at(&heap, numbers, i), number(0))
		expect_tagged(t, arr.element_at(&heap, booleans, i), boolean(false))
		expect_tagged(t, arr.element_at(&heap, values, i), abi.Tagged{})
		testing.expect(t, ([^]rawptr)(refs.elements)[i] == nil, "a Ref element that is not nil")
	}
	for array in ([?]^abi.Array_Cell{numbers, booleans, values, refs}) {
		testing.expect_value(t, array.length, 3)
		testing.expect(t, array.capacity >= 3, "no room for the elements")
	}

	empty := arr.new_zeroed(&heap, REFS, 0)
	testing.expect_value(t, empty.length, 0)
	testing.expect(t, empty.elements == nil, "an empty array with a buffer")
	problem, _ := gc.verify(&heap)
	testing.expect_value(t, problem, gc.Heap_Problem.None)
}

// The bound is ECMAScript's:
//
//	node -e 'const a = []; a.length = 2 ** 32 - 1; console.log(a.length); a.push(1)'
//
// prints the length, then throws "RangeError: Invalid array length".
@(test)
an_array_is_as_long_as_ecmascript_allows :: proc(t: ^testing.T) {
	testing.expect_value(t, arr.MAX_LENGTH, 4_294_967_295)
	testing.expect(t, arr.length_fits(arr.MAX_LENGTH))
	testing.expect(t, !arr.length_fits(arr.MAX_LENGTH + 1))
}

// A boolean element is one byte, the way generated code indexes it: push, growth and slice keep that
// stride.
@(test)
a_boolean_element_is_one_byte :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	flags := arr.new_array(&heap, BOOLEANS, 0)
	for i in 0 ..< 10 {
		arr.push(&heap, flags, boolean(i % 3 == 0))
	}
	part := arr.slice(&heap, flags, 1, 10)
	for i in 0 ..< 10 {
		want := u8(i % 3 == 0)
		testing.expect_value(t, ([^]u8)(flags.elements)[i], want)
		if i > 0 {
			testing.expect_value(t, ([^]u8)(part.elements)[i - 1], want)
		}
	}
}

// An empty result allocates nothing: a slice or a split with no elements has no buffer, and an
// empty join is the static empty string.
@(test)
an_empty_result_takes_no_buffer :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	a := numbers(&heap, 10, 20, 30)
	for bounds in ([?][2]f64{{2, 1}, {0, NEGATIVE_ZERO}, {3, INF}}) {
		part := arr.slice(&heap, a, bounds[0], bounds[1])
		testing.expect_value(t, part.length, 0)
		testing.expect_value(t, part.capacity, 0)
	}

	empty, comma := str.from_utf8(&heap, ""), str.from_utf8(&heap, ",")
	pieces := [?]^abi.Array_Cell{arr.new_array(&heap, REFS, 0), arr.new_array(&heap, REFS, 0)}
	arr.split(&heap, pieces[0], empty, empty, abi.MISSING_LIMIT)
	arr.split(&heap, pieces[1], str.from_utf8(&heap, "a,b"), comma, 0)
	for p in pieces {
		testing.expect_value(t, p.length, 0)
		testing.expect_value(t, p.capacity, 0)
	}

	joined, ok := arr.join(&heap, arr.new_array(&heap, NUMBERS, 0), comma)
	testing.expect(t, ok, "an empty array refused")
	testing.expect_value(t, joined.length, 0)
	testing.expect(t, gc.owner(&heap, joined) == nil, "the empty string took a cell")
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

boolean :: proc(b: bool) -> abi.Tagged {
	return {tag = .Boolean, payload = {boolean = b64(b)}}
}

number :: proc(n: f64) -> abi.Tagged {
	return {tag = .Number, payload = {number = n}}
}

text :: proc(cell: ^abi.String_Cell) -> abi.Tagged {
	return {tag = .String, payload = {ref = cell}}
}

// with_method makes an object of a table whose one field, at offset 8, holds a function: an object
// with its own toString or valueOf, as a program makes one.
with_method :: proc(heap: ^gc.Heap, table: abi.Type_Table_ID) -> ^abi.Cell_Header {
	closure := gc.alloc(heap, CLOSURE, size_of(abi.Closure_Cell))
	cell := gc.alloc(heap, table, 16)
	(^^abi.Cell_Header)(&([^]byte)(cell)[8])^ = closure
	return cell
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
