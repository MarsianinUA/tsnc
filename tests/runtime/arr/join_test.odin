package arr_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

// Node prints a function's source text and calls an object's own toString; tsnc has neither, at
// any depth.
@(test)
join_refuses_what_node_would_run :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	comma := str.from_utf8(&heap, ",")
	printable := arr.new_array(&heap, REFS, 0)
	arr.push(&heap, printable, object(with_method(&heap, PRINTABLE)))
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

	own := object(with_method(&heap, VALUE_OF))
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
