package value_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"
import "../../../src/runtime/value"

/*
What typeof, ===, truthiness and String answer for each tag is pinned by the program
tests/diff/src/any-values.ts; the tests here check what no program can see. They stay far below
gc.MIN_TRIGGER, so no collection runs and their cells may live in the test procedure.
*/

RESERVE :: 16 * gc.PAGE_SIZE

// The program tables TABLES registers, numbered after the builtin ones.
POINT :: abi.Type_Table_ID(len(abi.Builtin_Table))
PRINTABLE :: POINT + 1
ARRAY :: POINT + 2
CLOSURE :: POINT + 3
MAYBE_PRINTABLE :: POINT + 4

TABLES := []abi.Type_Table {
	{kind = .Object, size = 16, fields = {{name = "x", offset = 8, kind = .Number}}},
	{kind = .Object, size = 16, fields = {{name = "toString", offset = 8, kind = .Ref}}},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Number},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
	{
		kind = .Object,
		size = 24,
		fields = {{name = "toString", offset = 8, kind = .Tagged, optional = true}},
	},
}

// Node prints a function's source text and calls an object's own toString; tsnc has neither. A
// toString set to a value that is no function makes Node throw:
//
//	node -e 'try { String({toString: 1}) } catch (e) { console.log(e.name) }'
//
// prints `TypeError`.
@(test)
to_string_refuses_what_node_would_run :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	closure := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))
	_, function_ok := value.to_string(&heap, function(closure))
	testing.expect(t, !function_ok, "a function converted")

	printable := gc.alloc(&heap, PRINTABLE, 16)
	(^^abi.Cell_Header)(&([^]byte)(printable)[8])^ = closure
	_, object_ok := value.to_string(&heap, object(printable))
	testing.expect(t, !object_ok, "an object with its own toString converted")

	set := gc.alloc(&heap, MAYBE_PRINTABLE, 24)
	(^abi.Tagged)(&([^]byte)(set)[8])^ = number(1)
	_, set_ok := value.to_string(&heap, object(set))
	testing.expect(t, !set_ok, "a toString that is no function converted")
}

// typeof answers a static word for every tag, and String a static one for undefined, null and a
// boolean: none of them allocates. A string is its own string, the same cell.
@(test)
the_words_take_no_cell :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	cell := str.from_utf8(&heap, "a")
	values := [?]abi.Tagged {
		{},
		null(),
		boolean(true),
		number(1.5),
		text(cell),
		object(gc.alloc(&heap, POINT, 16)),
		object(gc.alloc(&heap, ARRAY, size_of(abi.Array_Cell))),
		function(gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))),
	}
	used := heap.used
	for v in values {
		word := value.typeof_word(v)
		testing.expectf(t, gc.owner(&heap, word) == nil, "typeof %v is a heap cell", v.tag)
	}
	for v in ([?]abi.Tagged{{}, null(), boolean(false), boolean(true)}) {
		got, _ := value.to_string(&heap, v)
		testing.expectf(t, gc.owner(&heap, got) == nil, "String of %v is a heap cell", v.tag)
	}
	testing.expect_value(t, heap.used, used)

	got, ok := value.to_string(&heap, text(cell))
	testing.expect(t, ok, "a string refused")
	testing.expect_value(t, got, cell)
}

// load boxes a slot of each kind, and a reference takes the tag typeof would answer for its cell.
@(test)
load_boxes_a_slot_of_each_kind :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	number_slot := f64(2.5)
	flag := b64(true)
	cells := [?]^abi.Cell_Header {
		str.from_utf8(&heap, "a"),
		gc.alloc(&heap, POINT, 16),
		gc.alloc(&heap, ARRAY, size_of(abi.Array_Cell)),
		gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell)),
	}
	tags := [?]abi.Tag{.String, .Object, .Object, .Function}
	tagged := abi.Tagged{.Null, {}}

	got_number := value.load(&heap, &number_slot, .Number)
	testing.expect(t, got_number.tag == .Number && got_number.payload.number == 2.5)
	got_flag := value.load(&heap, &flag, .Boolean)
	testing.expect(t, got_flag.tag == .Boolean && bool(got_flag.payload.boolean))
	testing.expect_value(t, value.load(&heap, &tagged, .Tagged).tag, abi.Tag.Null)
	for &cell, i in cells {
		got := value.load(&heap, &cell, .Ref)
		testing.expect_value(t, got.tag, tags[i])
		testing.expect(t, got.payload.ref == cell)
	}
}

@(private = "file")
init_heap :: proc(t: ^testing.T, heap: ^gc.Heap, loc := #caller_location) {
	err := gc.heap_init(heap, TABLES, nil, heap, reserve = RESERVE)
	testing.expect_value(t, err, gc.Heap_Error.None, loc = loc)
}

@(private = "file")
null :: proc() -> abi.Tagged {
	return {tag = .Null}
}

@(private = "file")
boolean :: proc(b: bool) -> abi.Tagged {
	return {tag = .Boolean, payload = {boolean = b64(b)}}
}

@(private = "file")
number :: proc(n: f64) -> abi.Tagged {
	return {tag = .Number, payload = {number = n}}
}

@(private = "file")
text :: proc(cell: ^abi.String_Cell) -> abi.Tagged {
	return {tag = .String, payload = {ref = cell}}
}

@(private = "file")
object :: proc(cell: ^abi.Cell_Header) -> abi.Tagged {
	return {tag = .Object, payload = {ref = cell}}
}

@(private = "file")
function :: proc(cell: ^abi.Cell_Header) -> abi.Tagged {
	return {tag = .Function, payload = {ref = cell}}
}
