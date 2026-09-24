package arr_tests

import "base:intrinsics"
import "base:runtime"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Stress mode: every allocation collects first and checks the heap after, so a cell an arr procedure
still needs and failed to keep would be freed under it, and a reference to a freed cell ends the
run with a heap check failure. The heap under test is a local of the test procedure and bounds the
stack scan, so the cells live in the procedures it calls, as in tests/runtime/gc.
*/

@(test)
every_allocation_keeps_its_sources :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, .Stress)
	defer gc.heap_destroy(&heap)

	call_every_allocating_procedure(t, &heap)
	problem, _ := gc.verify(&heap)
	testing.expect_value(t, problem, gc.Heap_Problem.None)
}

// The comparator pops every element off the array and allocates on each call. Only the sort's copy
// still holds the strings then, and each allocation collects.
@(test)
the_copy_keeps_what_a_comparator_pops :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, .Stress)
	defer gc.heap_destroy(&heap)

	sort_while_popping(t, &heap)
	problem, _ := gc.verify(&heap)
	testing.expect_value(t, problem, gc.Heap_Problem.None)
}

// On its first call the comparator pushes a new string, pops two, and sorts the same array with
// itself, while every allocation collects. The outer sort then sets the three words it copied, as
// Node does:
//
//	node -e 'const w = ["cherry", "apple", "banana"]; let n = 0; const by = (a, b) => { if (n++ === 0) { w.push("date"); w.pop(); w.pop(); w.sort(by) } return a < b ? -1 : a > b ? 1 : 0 }; w.sort(by); console.log(w)'
@(test)
a_comparator_may_push_pop_and_sort_again :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap, .Stress)
	defer gc.heap_destroy(&heap)

	sort_while_sorting(t, &heap)
	problem, _ := gc.verify(&heap)
	testing.expect_value(t, problem, gc.Heap_Problem.None)
}

@(private = "file")
call_every_allocating_procedure :: #force_no_inline proc(t: ^testing.T, heap: ^gc.Heap) {
	// The string lives only in push's argument while the first push grows the buffer.
	words := arr.new_array(heap, REFS, 0)
	arr.push(heap, words, text(str.from_utf8(heap, "fresh")))
	arr.push(heap, words, text(str.from_utf8(heap, "b")))
	arr.push(heap, words, text(str.from_utf8(heap, "a")))

	digits := numbers(heap, 10, 9, 1, 100)
	part := arr.slice(heap, digits, 1, 3)
	pieces := arr.split(
		heap,
		str.from_utf8(heap, "x,yy,zzz"),
		str.from_utf8(heap, ","),
		abi.MISSING_LIMIT,
	)
	joined, _ := arr.join(heap, pieces, str.from_utf8(heap, "+"))
	nested := arr.new_array(heap, VALUES, 0)
	arr.push(heap, nested, object(digits))
	arr.push(heap, nested, text(str.from_utf8(heap, "end")))
	converted, _ := arr.to_string(heap, object(nested))
	arr.sort_default(heap, digits)
	arr.sort_default(heap, words)
	allocating := Stub {
		heap = heap,
	}
	arr.sort(
		heap,
		part,
		&abi.Closure_Cell{code = rawptr(allocate_then_descend), env = environment(&allocating)},
	)

	// Generated code fills a zeroed array in place, one allocating element at a time, so every
	// collection meanwhile meets the nil elements not stored yet.
	filled := arr.new_zeroed(heap, REFS, 3)
	for word, i in ([?]string{"x", "y", "z"}) {
		([^]^abi.String_Cell)(filled.elements)[i] = str.from_utf8(heap, word)
	}

	for want, i in ([?]string{"a", "b", "fresh"}) {
		expect_ascii(t, (^abi.String_Cell)(arr.element_at(heap, words, i).payload.ref), want)
	}
	for want, i in ([?]string{"x", "y", "z"}) {
		expect_ascii(t, (^abi.String_Cell)(arr.element_at(heap, filled, i).payload.ref), want)
	}
	expect_numbers(t, heap, digits, {1, 10, 100, 9})
	expect_numbers(t, heap, part, {9, 1})
	expect_ascii(t, joined, "x+yy+zzz")
	expect_ascii(t, converted, "10,9,1,100,end")
}

@(private = "file")
sort_while_popping :: #force_no_inline proc(t: ^testing.T, heap: ^gc.Heap) {
	words := words_only_the_array_holds(heap)
	scrub_stack()
	popper := Stub {
		heap  = heap,
		array = words,
	}
	arr.sort(
		heap,
		words,
		&abi.Closure_Cell{code = rawptr(pop_all_then_compare), env = environment(&popper)},
	)
	for want, i in ([?]string{"apple", "banana", "cherry"}) {
		expect_ascii(t, (^abi.String_Cell)(arr.element_at(heap, words, i).payload.ref), want)
	}
}

@(private = "file")
sort_while_sorting :: #force_no_inline proc(t: ^testing.T, heap: ^gc.Heap) {
	words := words_only_the_array_holds(heap)
	scrub_stack()
	stub := Stub {
		heap  = heap,
		array = words,
	}
	arr.sort(
		heap,
		words,
		&abi.Closure_Cell{code = rawptr(push_pop_and_sort_once), env = environment(&stub)},
	)
	testing.expect_value(t, words.length, 3)
	for want, i in ([?]string{"apple", "banana", "cherry"}) {
		expect_ascii(t, (^abi.String_Cell)(arr.element_at(heap, words, i).payload.ref), want)
	}
}

@(private = "file")
words_only_the_array_holds :: #force_no_inline proc(heap: ^gc.Heap) -> ^abi.Array_Cell {
	words := arr.new_array(heap, REFS, 0)
	for word in ([?]string{"cherry", "apple", "banana"}) {
		arr.push(heap, words, text(str.from_utf8(heap, word)))
	}
	return words
}

@(private = "file")
allocate_then_descend :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	context = runtime.default_context()
	str.from_utf8((^Stub)(env).heap, "garbage")
	return b - a
}

@(private = "file")
pop_all_then_compare :: proc "c" (env: ^abi.Environment_Cell, a, b: ^abi.Cell_Header) -> f64 {
	context = runtime.default_context()
	stub := (^Stub)(env)
	for stub.array.length > 0 {
		arr.pop(stub.heap, stub.array)
	}
	str.from_utf8(stub.heap, "garbage")
	x, y := (^abi.String_Cell)(a), (^abi.String_Cell)(b)
	return f64(str.compare_units(str.units(x), str.units(y)))
}

@(private = "file")
push_pop_and_sort_once :: proc "c" (env: ^abi.Environment_Cell, a, b: ^abi.Cell_Header) -> f64 {
	context = runtime.default_context()
	stub := (^Stub)(env)
	stub.calls += 1
	if stub.calls == 1 {
		arr.push(stub.heap, stub.array, text(str.from_utf8(stub.heap, "date")))
		arr.pop(stub.heap, stub.array)
		arr.pop(stub.heap, stub.array)
		again := abi.Closure_Cell {
			code = rawptr(push_pop_and_sort_once),
			env  = env,
		}
		arr.sort(stub.heap, stub.array, &again)
	}
	x, y := (^abi.String_Cell)(a), (^abi.String_Cell)(b)
	return f64(str.compare_units(str.units(x), str.units(y)))
}

// scrub_stack writes over the stack below its caller, where earlier frames left copies of the
// pointers they handled, as tests/runtime/str does: one volatile store per word, which -o:speed
// keeps where it deletes a volatile memset, and no ASan redzones around the buffer.
@(private = "file", no_sanitize_address)
scrub_stack :: #force_no_inline proc() {
	buffer: [2048]u64 = ---
	for &word in buffer {
		intrinsics.volatile_store(&word, 0)
	}
}
