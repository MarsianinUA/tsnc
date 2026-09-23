package value_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"
import "../../../src/runtime/value"

/*
Every expected value came out of Node 24:

	node -e 'for (const v of [undefined, null, true, 0, -0, NaN, "", "0", {}, [], () => 1]) console.log(typeof v, !!v, String(v))'

The tests stay far below gc.MIN_TRIGGER, so no collection runs and their cells may live in the
test procedure.
*/

NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

RESERVE :: 16 * gc.PAGE_SIZE

// The program tables TABLES registers, numbered after the builtin ones.
POINT :: abi.Type_Table_ID(len(abi.Builtin_Table))
PRINTABLE :: POINT + 1
ARRAY :: POINT + 2
CLOSURE :: POINT + 3

TABLES := []abi.Type_Table {
	{kind = .Object, size = 16, fields = {{name = "x", offset = 8, kind = .Number}}},
	{kind = .Object, size = 16, fields = {{name = "toString", offset = 8, kind = .Ref}}},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Number},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
}

@(test)
typeof_answers_a_static_word_for_every_tag :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	cases := [?]struct {
		value: abi.Tagged,
		word:  string,
	} {
		{abi.Tagged{}, "undefined"},
		{null(), "object"},
		{boolean(true), "boolean"},
		{number(1.5), "number"},
		{text(str.from_utf8(&heap, "a")), "string"},
		{object(gc.alloc(&heap, POINT, 16)), "object"},
		{object(gc.alloc(&heap, ARRAY, size_of(abi.Array_Cell))), "object"},
		{function(gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))), "function"},
	}
	used := heap.used
	for c in cases {
		got := value.typeof_word(c.value)
		expect_ascii(t, got, c.word)
		testing.expectf(t, gc.owner(&heap, got) == nil, "typeof %v is a heap cell", c.value.tag)
	}
	testing.expect_value(t, heap.used, used)
}

@(test)
strict_equality_goes_by_tag :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	ab := str.from_utf8(&heap, "ab")
	twin := str.from_utf8(&heap, "ab")
	testing.expect(t, ab != twin, "two cells of one content")
	ac := str.from_utf8(&heap, "ac")
	empty := str.from_utf8(&heap, "")
	one := str.from_utf8(&heap, "1")
	point := gc.alloc(&heap, POINT, 16)
	other_point := gc.alloc(&heap, POINT, 16)
	f := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))
	g := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))

	// Typed locals: Odin folds untyped constant arithmetic exactly, which would make 0.1 + 0.2 the
	// double nearest 0.3.
	tenth, fifth := f64(0.1), f64(0.2)
	cases := [?]struct {
		a, b: abi.Tagged,
		want: bool,
	} {
		{number(NAN), number(NAN), false},
		{number(NEGATIVE_ZERO), number(0), true},
		{number(1.5), number(1.5), true},
		{number(tenth + fifth), number(0.3), false},
		{number(INF), number(INF), true},
		{boolean(true), boolean(true), true},
		{boolean(true), boolean(false), false},
		{abi.Tagged{}, abi.Tagged{}, true},
		{null(), null(), true},
		{abi.Tagged{}, null(), false},
		{number(0), boolean(false), false},
		{number(1), text(one), false},
		{number(0), abi.Tagged{}, false},
		{text(ab), text(twin), true},
		{text(ab), text(ac), false},
		{text(empty), text(str.from_utf8(&heap, "")), true},
		{text(empty), text(ab), false},
		{object(point), object(point), true},
		{object(point), object(other_point), false},
		{function(f), function(f), true},
		{function(f), function(g), false},
		{object(point), function(point), false},
	}
	for c, i in cases {
		testing.expectf(t, value.equal(c.a, c.b) == c.want, "case %d: want %v", i, c.want)
		testing.expectf(t, value.equal(c.b, c.a) == c.want, "case %d swapped: want %v", i, c.want)
	}
}

@(test)
truthiness_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	cases := [?]struct {
		value: abi.Tagged,
		want:  bool,
	} {
		{abi.Tagged{}, false},
		{null(), false},
		{boolean(false), false},
		{boolean(true), true},
		{number(0), false},
		{number(NEGATIVE_ZERO), false},
		{number(NAN), false},
		{number(1), true},
		{number(-1), true},
		{number(INF), true},
		{number(5e-324), true},
		{text(str.from_utf8(&heap, "")), false},
		{text(str.from_utf8(&heap, "0")), true},
		{text(str.from_utf8(&heap, " ")), true},
		{object(gc.alloc(&heap, POINT, 16)), true},
		{object(gc.alloc(&heap, ARRAY, size_of(abi.Array_Cell))), true},
		{function(gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))), true},
	}
	for c, i in cases {
		testing.expectf(t, value.to_boolean(c.value) == c.want, "case %d: want %v", i, c.want)
	}
}

@(test)
to_string_matches_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	tenth, fifth := f64(0.1), f64(0.2)
	cases := [?]struct {
		value: abi.Tagged,
		want:  string,
	} {
		{abi.Tagged{}, "undefined"},
		{null(), "null"},
		{boolean(true), "true"},
		{boolean(false), "false"},
		{number(NEGATIVE_ZERO), "0"},
		{number(NAN), "NaN"},
		{number(INF), "Infinity"},
		{number(-INF), "-Infinity"},
		{number(1e21), "1e+21"},
		{number(tenth + fifth), "0.30000000000000004"},
		{number(1.5), "1.5"},
		{object(gc.alloc(&heap, POINT, 16)), "[object Object]"},
	}
	for c in cases {
		got, ok := value.to_string(&heap, c.value)
		if testing.expectf(t, ok, "%v refused", c.value.tag) {
			expect_ascii(t, got, c.want)
		}
	}

	// Only the digits of a number take a cell; the words are static.
	for tag in ([?]abi.Tag{.Undefined, .Null, .Boolean}) {
		got, _ := value.to_string(&heap, {tag = tag})
		testing.expectf(t, gc.owner(&heap, got) == nil, "%v is a heap cell", tag)
	}

	// A string is its own string: the same cell comes back.
	cell := str.from_utf8(&heap, "abc")
	got, ok := value.to_string(&heap, text(cell))
	testing.expect(t, ok, "a string refused")
	testing.expect_value(t, got, cell)
}

// Node prints a function's source text and calls an object's own toString; tsnc has neither.
@(test)
to_string_refuses_what_node_would_run :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	closure := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))
	_, function_ok := value.to_string(&heap, function(closure))
	testing.expect(t, !function_ok, "a function converted")

	printable := gc.alloc(&heap, PRINTABLE, 16)
	_, object_ok := value.to_string(&heap, object(printable))
	testing.expect(t, !object_ok, "an object with its own toString converted")
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

@(private = "file")
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
