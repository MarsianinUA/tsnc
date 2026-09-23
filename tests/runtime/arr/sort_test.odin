package arr_tests

import "base:runtime"
import "core:math"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
The comparators are stubs written in Odin with the closure convention of abi, which is how a
comparator lower compiles will be called: the environment first, then the two elements the way a
runtime export takes them. Every expected order came out of Node 24:

	node -e 'console.log([2.5, 1.9, 2.1, 1.1, 2.0].sort((a, b) => Math.floor(a) - Math.floor(b)), [3, 1, 2].sort(() => NaN), [3, 1, 2].sort((a, b) => b - a))'
	node -e 'console.log([true, false, true].sort((a, b) => Number(a) - Number(b)), [3, undefined, 1, undefined, 2].sort((a, b) => a - b))'
	node -e 'const d = [3, 1, 2]; let once = true; d.sort((x, y) => { if (once) { once = false; d.push(9) } return x - y }); console.log(d)'
	node -e 'const e = [3, 1, 2]; let once = true; e.sort((x, y) => { if (once) { once = false; e.pop(); e.pop() } return x - y }); console.log(e)'
	node -e 'console.log([10, 9, 1, 100, -1, 0.5].sort(), [undefined, "o", null, "m", undefined].sort(), [[2], [1, 3], [1]].sort(), [0, -0].sort(), [true, false].sort())'
	node -e 'console.log(["\u0100", "\u00ff", "\uffff", "\u{1F600}", "a"].sort().map(s => s.charCodeAt(0).toString(16)))'
*/

// Stub is the environment a stub comparator reads: not a heap cell, which the sort does not mind,
// since it only hands the pointer on.
Stub :: struct {
	sign:          f64,
	calls:         int,
	saw_undefined: bool,
	heap:          ^gc.Heap,
	array:         ^abi.Array_Cell, // the array under sort, for the stubs that change it
}

@(test)
a_comparator_gets_its_environment_and_both_numbers :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	up := Stub {
		sign = 1,
	}
	a := numbers(&heap, 3, 1, 2)
	arr.sort(&heap, a, &abi.Closure_Cell{code = rawptr(by_difference), env = environment(&up)})
	expect_numbers(t, &heap, a, {1, 2, 3})
	testing.expect(t, up.calls > 0, "the comparator was never called")

	down := Stub {
		sign = -1,
	}
	arr.sort(&heap, a, &abi.Closure_Cell{code = rawptr(by_difference), env = environment(&down)})
	expect_numbers(t, &heap, a, {3, 2, 1})
}

@(test)
equal_elements_keep_their_order :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	a := numbers(&heap, 2.5, 1.9, 2.1, 1.1, 2.0)
	arr.sort(&heap, a, &abi.Closure_Cell{code = rawptr(by_integer_part)})
	expect_numbers(t, &heap, a, {1.9, 1.1, 2.5, 2.1, 2.0})

	// NaN from the comparator is 0: every pair is equal, and nothing moves.
	b := numbers(&heap, 3, 1, 2)
	arr.sort(&heap, b, &abi.Closure_Cell{code = rawptr(always_nan)})
	expect_numbers(t, &heap, b, {3, 1, 2})
}

@(test)
every_element_kind_reaches_the_comparator_in_its_own_shape :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	flags := arr.new_array(&heap, BOOLEANS, 0)
	for b in ([?]bool{true, false, true}) {
		arr.push(&heap, flags, boolean(b))
	}
	arr.sort(&heap, flags, &abi.Closure_Cell{code = rawptr(false_first)})
	for want, i in ([?]bool{false, true, true}) {
		expect_tagged(t, arr.element_at(&heap, flags, i), boolean(want))
	}

	words := arr.new_array(&heap, REFS, 0)
	for word in ([?]string{"b", "a", "c"}) {
		arr.push(&heap, words, text(str.from_utf8(&heap, word)))
	}
	arr.sort(&heap, words, &abi.Closure_Cell{code = rawptr(by_units)})
	for want, i in ([?]string{"a", "b", "c"}) {
		expect_ascii(t, (^abi.String_Cell)(arr.element_at(&heap, words, i).payload.ref), want)
	}

	// A tagged element arrives as its two words, and undefined never arrives at all.
	values := arr.new_array(&heap, VALUES, 0)
	for v in ([?]abi.Tagged{number(3), {}, number(1), {}, number(2)}) {
		arr.push(&heap, values, v)
	}
	seen: Stub
	arr.sort(
		&heap,
		values,
		&abi.Closure_Cell{code = rawptr(tagged_numbers), env = environment(&seen)},
	)
	testing.expect(t, !seen.saw_undefined, "undefined reached the comparator")
	for want, i in ([?]abi.Tagged{number(1), number(2), number(3), {}, {}}) {
		expect_tagged(t, arr.element_at(&heap, values, i), want)
	}
}

// Node sorts the elements it saw when the sort began and sets them over the array from index 0: a
// comparator that pushes leaves its element after them, one that pops makes the array grow back.
@(test)
a_comparator_that_changes_the_array_sees_node_semantics :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	grown := numbers(&heap, 3, 1, 2)
	pusher := Stub {
		heap  = &heap,
		array = grown,
	}
	arr.sort(
		&heap,
		grown,
		&abi.Closure_Cell{code = rawptr(push_nine_once), env = environment(&pusher)},
	)
	expect_numbers(t, &heap, grown, {1, 2, 3, 9})

	shrunk := numbers(&heap, 3, 1, 2)
	popper := Stub {
		heap  = &heap,
		array = shrunk,
	}
	arr.sort(
		&heap,
		shrunk,
		&abi.Closure_Cell{code = rawptr(pop_two_once), env = environment(&popper)},
	)
	expect_numbers(t, &heap, shrunk, {1, 2, 3})
}

@(test)
fewer_than_two_elements_call_nothing :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	for a in ([?]^abi.Array_Cell{numbers(&heap), numbers(&heap, 5)}) {
		stub: Stub
		used := heap.used
		arr.sort(
			&heap,
			a,
			&abi.Closure_Cell{code = rawptr(by_difference), env = environment(&stub)},
		)
		testing.expect_value(t, stub.calls, 0)
		testing.expect_value(t, heap.used, used)
	}
}

@(test)
the_default_order_is_the_order_of_strings :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	digits := numbers(&heap, 10, 9, 1, 100, -1, 0.5)
	testing.expect(t, arr.sort_default(&heap, digits), "numbers refused")
	expect_numbers(t, &heap, digits, {-1, 0.5, 1, 10, 100, 9})

	// Both zeros are "0", so they keep their order either way round.
	zeros := numbers(&heap, 0, NEGATIVE_ZERO)
	arr.sort_default(&heap, zeros)
	expect_numbers(t, &heap, zeros, {0, NEGATIVE_ZERO})

	flags := arr.new_array(&heap, BOOLEANS, 0)
	arr.push(&heap, flags, boolean(true))
	arr.push(&heap, flags, boolean(false))
	arr.sort_default(&heap, flags)
	expect_tagged(t, arr.element_at(&heap, flags, 0), boolean(false))

	// null is the string "null"; only undefined goes last.
	o, m := str.from_utf8(&heap, "o"), str.from_utf8(&heap, "m")
	values := arr.new_array(&heap, VALUES, 0)
	for v in ([?]abi.Tagged{{}, text(o), null(), text(m), {}}) {
		arr.push(&heap, values, v)
	}
	arr.sort_default(&heap, values)
	for want, i in ([?]abi.Tagged{text(m), null(), text(o), {}, {}}) {
		expect_tagged(t, arr.element_at(&heap, values, i), want)
	}

	// An inner array is its join: "2", "1,3", "1".
	two, one_three, one := numbers(&heap, 2), numbers(&heap, 1, 3), numbers(&heap, 1)
	lists := arr.new_array(&heap, REFS, 0)
	for list in ([?]^abi.Array_Cell{two, one_three, one}) {
		arr.push(&heap, lists, object(list))
	}
	arr.sort_default(&heap, lists)
	for want, i in ([?]^abi.Array_Cell{one, one_three, two}) {
		expect_tagged(t, arr.element_at(&heap, lists, i), object(want))
	}
}

// By 16-bit units, so a surrogate sorts below U+FFFF, and U+00FF below U+0100.
@(test)
the_default_order_compares_utf16_units :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	inputs := [?][]u16{{0x100}, {0xff}, {0xffff}, {0xd83d, 0xde00}, {'a'}}
	words := arr.new_array(&heap, REFS, 0)
	for units in inputs {
		arr.push(&heap, words, text(str.from_units(&heap, string16(units))))
	}
	arr.sort_default(&heap, words)
	for first, i in ([?]u16{'a', 0xff, 0x100, 0xd83d, 0xffff}) {
		element := arr.element_at(&heap, words, i)
		testing.expect_value(t, str.units((^abi.String_Cell)(element.payload.ref))[0], first)
	}
}

// Node sorts a function by its source text, which tsnc does not keep: the sort refuses and leaves
// the array as it was.
@(test)
the_default_order_refuses_a_function :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	closure := gc.alloc(&heap, CLOSURE, size_of(abi.Closure_Cell))
	values := arr.new_array(&heap, VALUES, 0)
	arr.push(&heap, values, function(closure))
	arr.push(&heap, values, number(2))
	testing.expect(t, !arr.sort_default(&heap, values), "a function sorted")
	expect_tagged(t, arr.element_at(&heap, values, 0), function(closure))
	expect_tagged(t, arr.element_at(&heap, values, 1), number(2))
}

environment :: proc(stub: ^Stub) -> ^abi.Environment_Cell {
	return (^abi.Environment_Cell)(stub)
}

by_difference :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	stub := (^Stub)(env)
	stub.calls += 1
	return (a - b) * stub.sign
}

by_integer_part :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	return math.floor(a) - math.floor(b)
}

always_nan :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	return NAN
}

false_first :: proc "c" (env: ^abi.Environment_Cell, a, b: b64) -> f64 {
	return f64(u64(a)) - f64(u64(b))
}

by_units :: proc "c" (env: ^abi.Environment_Cell, a, b: ^abi.Cell_Header) -> f64 {
	x, y := (^abi.String_Cell)(a), (^abi.String_Cell)(b)
	return f64(str.compare_units(str.units(x), str.units(y)))
}

tagged_numbers :: proc "c" (
	env: ^abi.Environment_Cell,
	a_tag: abi.Tag,
	a_payload: u64,
	b_tag: abi.Tag,
	b_payload: u64,
) -> f64 {
	stub := (^Stub)(env)
	stub.saw_undefined ||= a_tag == .Undefined || b_tag == .Undefined
	return transmute(f64)a_payload - transmute(f64)b_payload
}

push_nine_once :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	context = runtime.default_context()
	stub := (^Stub)(env)
	if stub.calls == 0 {
		arr.push(stub.heap, stub.array, number(9))
	}
	stub.calls += 1
	return a - b
}

pop_two_once :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	context = runtime.default_context()
	stub := (^Stub)(env)
	if stub.calls == 0 {
		arr.pop(stub.heap, stub.array)
		arr.pop(stub.heap, stub.array)
	}
	stub.calls += 1
	return a - b
}
