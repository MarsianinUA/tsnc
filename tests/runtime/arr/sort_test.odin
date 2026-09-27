package arr_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/gc"

/*
The comparators are stubs written in Odin with the closure convention of abi, which is how a
comparator lower compiles will be called: the environment first, then the two elements the way a
runtime export takes them.
*/

// Stub is the environment a stub comparator reads: not a heap cell, which the sort does not mind,
// since it only hands the pointer on.
Stub :: struct {
	sign:  f64,
	calls: int,
	heap:  ^gc.Heap,
	array: ^abi.Array_Cell, // the array under sort, for the stubs that change it
}

// A sorted and a reversed array cost n - 1 calls each, as in Node; a shuffled one n log2 n at most.
//
//	node -e 'let c = 0; Array.from({length: 1000}, (_, i) => 999 - i).sort((a, b) => { c++; return a - b }); console.log(c)'
@(test)
a_comparator_is_called_as_often_as_in_node :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	N :: 1000
	LOG2_N :: 10 // rounded up
	sorted, reversed, shuffled := numbers(&heap), numbers(&heap), numbers(&heap)
	state := u64(1)
	for i in 0 ..< N {
		arr.push(&heap, sorted, number(f64(i)))
		arr.push(&heap, reversed, number(f64(N - 1 - i)))
		arr.push(&heap, shuffled, number(f64(random(&state) % N)))
	}
	for a, i in ([?]^abi.Array_Cell{sorted, reversed, shuffled}) {
		stub := Stub {
			sign = 1,
		}
		arr.sort(
			&heap,
			a,
			&abi.Closure_Cell{code = rawptr(by_difference), env = environment(&stub)},
		)
		if i < 2 {
			testing.expectf(t, stub.calls == N - 1, "array %d: %d calls", i, stub.calls)
		} else {
			testing.expectf(t, stub.calls <= N * LOG2_N, "shuffled: %d calls", stub.calls)
		}
		expect_ascending(t, &heap, a)
	}
}

// A comparator that contradicts itself leaves the order to the implementation, but every element
// is still there once.
@(test)
an_inconsistent_comparator_still_permutes :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	N :: 1000
	a := numbers(&heap)
	for i in 0 ..< N {
		arr.push(&heap, a, number(f64(i)))
	}
	stub: Stub
	arr.sort(&heap, a, &abi.Closure_Cell{code = rawptr(contradict), env = environment(&stub)})
	testing.expect_value(t, a.length, N)
	seen: [N]bool
	for i in 0 ..< N {
		x := int(arr.element_at(&heap, a, i).payload.number)
		testing.expectf(t, !seen[x], "%d is there twice", x)
		seen[x] = true
	}
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

contradict :: proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64 {
	stub := (^Stub)(env)
	stub.calls += 1
	answers := [?]f64{-1, 1, NAN, -INF}
	return answers[stub.calls % len(answers)]
}

expect_ascending :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	loc := #caller_location,
) {
	for i in 1 ..< array.length {
		x, y := arr.element_at(heap, array, i - 1), arr.element_at(heap, array, i)
		if x.payload.number > y.payload.number {
			testing.expectf(
				t,
				false,
				"%v comes before %v",
				x.payload.number,
				y.payload.number,
				loc = loc,
			)
			return
		}
	}
}

// random is xorshift64, which shuffles a test array the same way on every run.
random :: proc(state: ^u64) -> u64 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 7
	state^ ~= state^ << 17
	return state^
}
