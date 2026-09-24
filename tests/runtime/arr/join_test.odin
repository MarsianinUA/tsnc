package arr_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"
import "../../../src/runtime/value"

/*
Every expected value came out of Node 24:

	node -e 'console.log([1, 2.5, -0, NaN, 1e21].join(), [true, false].join(), ["a", "b"].join("\u{1F600}"), ["a", "b", "c"].join(""), [[1, [2, 3]], [], 4].join(), [].join(), [{x: 1}].join())'
	node -e 'const a = [1]; a.push(a); a.push(2); const b = [1]; const c = [2, b]; b.push(c); console.log(a.join(), b.join(), c.join("-"))'
	node -e 'console.log([1, undefined, null, true, "x"].join("-"))'
*/

@(test)
join_writes_every_element_as_node_does :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	comma := str.from_utf8(&heap, ",")
	expect_join(
		t,
		&heap,
		numbers(&heap, 1, 2.5, NEGATIVE_ZERO, NAN, 1e21),
		comma,
		"1,2.5,0,NaN,1e+21",
	)

	flags := arr.new_array(&heap, BOOLEANS, 0)
	arr.push(&heap, flags, boolean(true))
	arr.push(&heap, flags, boolean(false))
	expect_join(t, &heap, flags, comma, "true,false")

	letters := arr.new_array(&heap, REFS, 0)
	for letter in ([?]string{"a", "b", "c"}) {
		arr.push(&heap, letters, text(str.from_utf8(&heap, letter)))
	}
	expect_join(t, &heap, letters, str.from_utf8(&heap, ""), "abc")
	emoji := [?]u16{0xd83d, 0xde00}
	joined, ok := arr.join(&heap, letters, str.from_units(&heap, string16(emoji[:])))
	testing.expect(t, ok, "letters refused")
	expect_units(t, joined, {'a', 0xd83d, 0xde00, 'b', 0xd83d, 0xde00, 'c'})

	// undefined and null add nothing, where String() would spell them.
	values := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, values, number(1))
	arr.push(&heap, values, abi.Tagged{})
	arr.push(&heap, values, null())
	arr.push(&heap, values, boolean(true))
	arr.push(&heap, values, text(str.from_utf8(&heap, "x")))
	expect_join(t, &heap, values, str.from_utf8(&heap, "-"), "1---true-x")

	objects := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, objects, object(gc.alloc(&heap, POINT, 16)))
	expect_join(t, &heap, objects, comma, "[object Object]")

	empty, empty_ok := arr.join(&heap, arr.new_array(&heap, NUMBERS, 0), comma)
	testing.expect(t, empty_ok, "an empty array refused")
	expect_ascii(t, empty, "")
	testing.expect(t, gc.owner(&heap, empty) == nil, "the empty string took a cell")
}

// [[1, [2, 3]], [], 4].join(): an inner array joins by commas whatever the outer separator is.
@(test)
a_nested_array_joins_in_place :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	first := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, first, number(1))
	arr.push(&heap, first, object(numbers(&heap, 2, 3)))
	outer := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, outer, object(first))
	arr.push(&heap, outer, object(arr.new_array(&heap, NUMBERS, 0)))
	arr.push(&heap, outer, number(4))
	expect_join(t, &heap, outer, str.from_utf8(&heap, ","), "1,2,3,,4")
	expect_join(t, &heap, outer, str.from_utf8(&heap, " "), "1,2,3  4")
}

// An array joined inside its own join adds nothing, as in V8.
@(test)
a_cycle_joins_to_nothing_where_it_closes :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	comma := str.from_utf8(&heap, ",")
	a := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, a, number(1))
	arr.push(&heap, a, object(a))
	arr.push(&heap, a, number(2))
	expect_join(t, &heap, a, comma, "1,,2")

	b := arr.new_array(&heap, VALUES, 0)
	c := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, b, number(1))
	arr.push(&heap, c, number(2))
	arr.push(&heap, c, object(b))
	arr.push(&heap, b, object(c))
	expect_join(t, &heap, b, comma, "1,2,")
	expect_join(t, &heap, c, str.from_utf8(&heap, "-"), "2-1,")
}

// Node prints a function's source text and calls an object's own toString; tsnc has neither, at
// any depth.
@(test)
join_refuses_what_node_would_run :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	comma := str.from_utf8(&heap, ",")
	printable := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, printable, object(gc.alloc(&heap, PRINTABLE, 16)))
	_, printable_ok := arr.join(&heap, printable, comma)
	testing.expect(t, !printable_ok, "an object with its own toString joined")

	nested := arr.new_array(&heap, VALUES, 0)
	functions := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, functions, function(gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))))
	arr.push(&heap, nested, object(functions))
	_, nested_ok := arr.join(&heap, nested, comma)
	testing.expect(t, !nested_ok, "a function inside an inner array joined")
	_, string_ok := arr.to_string(&heap, object(nested))
	testing.expect(t, !string_ok, "ToString of the same array converted")
}

// append_string is ToString without the cell: an array joins by commas, and what to_string refuses
// it refuses too.
@(test)
append_string_writes_to_string_into_the_units :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	units := make([dynamic]u16, context.temp_allocator)
	inner := numbers(&heap, 2, 3)
	outer := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, outer, number(1))
	arr.push(&heap, outer, object(inner))
	testing.expect(t, arr.append_string(&units, &heap, number(-1.5)))
	testing.expect(t, arr.append_string(&units, &heap, null()))
	testing.expect(t, arr.append_string(&units, &heap, object(outer)))
	want := "-1.5null1,2,3"
	same := len(units) == len(want)
	for i in 0 ..< min(len(units), len(want)) {
		same &&= units[i] == u16(want[i])
	}
	testing.expectf(t, same, "got %v, want %q", units[:], want)

	closure := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))
	testing.expect(t, !arr.append_string(&units, &heap, function(closure)), "a function converted")
}

// String(x) of an array is its join by commas; of anything else it is what package value says.
@(test)
to_string_joins_an_array_and_leaves_the_rest_to_value :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	inner := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, inner, number(2))
	arr.push(&heap, inner, object(numbers(&heap, 3)))
	outer := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, outer, number(1))
	arr.push(&heap, outer, object(inner))
	joined, ok := arr.to_string(&heap, object(outer))
	testing.expect(t, ok, "an array refused")
	expect_ascii(t, joined, "1,2,3")

	cell := str.from_utf8(&heap, "abc")
	for v in ([?]abi.Tagged{abi.Tagged{}, null(), boolean(false), number(1.5), text(cell)}) {
		got, got_ok := arr.to_string(&heap, v)
		want, want_ok := value.to_string(&heap, v)
		testing.expect(t, got_ok && want_ok, "a primitive refused")
		testing.expect(t, str.equal(got, want), "arr and value disagree")
	}
	same, _ := arr.to_string(&heap, text(cell))
	testing.expect_value(t, same, cell)
}

// `"" + x` asks ToPrimitive, which asks an object for its own valueOf before its toString; an
// array's elements go through ToString, which does not:
//
//	node -e 'console.log("" + {valueOf: () => 1}, "" + [{valueOf: () => 1}], "" + {x: 1})'
//
// prints `1 [object Object] [object Object]`.
@(test)
to_primitive_string_refuses_an_object_with_its_own_value_of :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	own := object(gc.alloc(&heap, VALUE_OF, 16))
	_, own_ok := arr.to_primitive_string(&heap, own)
	testing.expect(t, !own_ok, "an object with its own valueOf converted")
	text, text_ok := arr.to_string(&heap, own)
	testing.expect(t, text_ok, "ToString asked for valueOf")
	expect_ascii(t, text, "[object Object]")

	holder := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, holder, own)
	joined, joined_ok := arr.to_primitive_string(&heap, object(holder))
	testing.expect(t, joined_ok, "an array holding such an object refused")
	expect_ascii(t, joined, "[object Object]")

	plain, plain_ok := arr.to_primitive_string(&heap, object(gc.alloc(&heap, POINT, 16)))
	testing.expect(t, plain_ok, "a plain object refused")
	expect_ascii(t, plain, "[object Object]")
	digits, digits_ok := arr.to_primitive_string(&heap, number(1.5))
	testing.expect(t, digits_ok, "a number refused")
	expect_ascii(t, digits, "1.5")
}

expect_join :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	separator: ^abi.String_Cell,
	want: string,
	loc := #caller_location,
) {
	joined, ok := arr.join(heap, array, separator)
	if testing.expectf(t, ok, "join refused, want %q", want, loc = loc) {
		expect_ascii(t, joined, want, loc = loc)
	}
}
