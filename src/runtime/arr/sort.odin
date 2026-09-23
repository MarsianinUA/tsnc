package arr

import "../../abi"
import "../gc"
import "../str"

/*
Array.prototype.sort, with a comparator and without one (requirements 4.5, row "Array sorting").
Both run the same way: the elements are copied into a new array that nothing else holds, a merge
sort orders a scratch list of indices into the copy, and the order is written back.

The copy is what keeps a comparator safe. It is TypeScript code, so it may allocate, and so collect,
and it may push to the array or pop from it. The collector scans the copy as an array of the same
table, so an element the comparator popped stays alive, and nothing moves under the sort: it reads
only the copy, whose buffer never grows. Indices are what move, never elements, so no element is
held only in a register of the sort while a comparator runs. The write-back follows the
specification's Set: an index past a length the comparator shortened appends.

undefined goes last and never reaches a comparator. The sort is stable, as ECMAScript asks, and a
natural merge sort in the manner of TimSort, which V8 runs: a sorted or a reversed array costs
n - 1 comparator calls, as in V8, and a shuffled one about n log2 n. The order of the calls is not
V8's, which a program that prints inside its comparator can see.
*/

// The shapes of a comparator's code by the element kind of the array, in the closure convention of
// abi: the environment first, nil when nothing is captured, then the two elements the way a runtime
// export takes them.
@(private)
Compare_Numbers :: #type proc "c" (env: ^abi.Environment_Cell, a, b: f64) -> f64
@(private)
Compare_Booleans :: #type proc "c" (env: ^abi.Environment_Cell, a, b: b64) -> f64
@(private)
Compare_Refs :: #type proc "c" (env: ^abi.Environment_Cell, a, b: ^abi.Cell_Header) -> f64
@(private)
Compare_Tagged :: #type proc "c" (
	env: ^abi.Environment_Cell,
	a_tag: abi.Tag,
	a_payload: u64,
	b_tag: abi.Tag,
	b_payload: u64,
) -> f64

// Sort_State lives on the stack of the sort, where the collector sees the copy and the closure.
@(private)
Sort_State :: struct {
	items:   ^abi.Array_Cell, // the copy
	kind:    abi.Slot_Kind,
	order:   []int, // indices into items of the elements that are not undefined
	compare: ^abi.Closure_Cell, // sort
	keys:    []string16, // sort_default: ToString of each item, by index into items
}

// MIN_RUN is the length a shorter run grows to by binary insertion before the merges. TimSort
// picks it between 32 and 64.
@(private)
MIN_RUN :: 32

// sort orders the array by `compare`, a closure whose code has the Compare_ shape of the array's
// element kind.
sort :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, compare: ^abi.Closure_Cell) {
	if array.length < 2 {
		return
	}
	state := start_sort(heap, array)
	defer delete(state.order)
	state.compare = compare
	merge_sort(&state)
	write_back(heap, array, &state)
}

// sort_default orders the array by the ToString of its elements, by 16-bit units. ok = false where
// value.to_string refuses an element, and then the array is left as it was.
sort_default :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell) -> (ok: bool) {
	if array.length < 2 {
		return true
	}
	state := start_sort(heap, array)
	defer delete(state.order)

	// The keys are views into one pool, taken once the pool has stopped moving.
	pool := make([dynamic]u16)
	defer delete(pool)
	spans := make([][2]int, state.items.length)
	defer delete(spans)
	for index in state.order {
		start := len(pool)
		item := load(heap, slot(state.items, state.kind, index), state.kind)
		write_string(&pool, heap, item, nil) or_return
		spans[index] = {start, len(pool)}
	}
	state.keys = make([]string16, state.items.length)
	defer delete(state.keys)
	for index in state.order {
		state.keys[index] = string16(pool[spans[index][0]:spans[index][1]])
	}

	merge_sort(&state)
	write_back(heap, array, &state)
	return true
}

// start_sort copies the array and lists the indices of its elements that are not undefined; only a
// tagged element can be undefined.
@(private)
start_sort :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell) -> Sort_State {
	items := slice(heap, array, 0, f64(array.length))
	kind := element_kind(heap, items)
	order := make([dynamic]int, 0, items.length)
	for i in 0 ..< items.length {
		if kind == .Tagged && (^abi.Tagged)(slot(items, kind, i)).tag == .Undefined {
			continue
		}
		append(&order, i)
	}
	return {items = items, kind = kind, order = order[:]}
}

// merge_sort leaves a permutation even for a comparator that contradicts itself: every step moves
// indices and never loses or copies one.
@(private)
merge_sort :: proc(state: ^Sort_State) {
	order := state.order
	ends := make([dynamic]int)
	defer delete(ends)
	for start := 0; start < len(order); {
		end := run_end(state, order, start)
		if end - start < MIN_RUN {
			limit := min(start + MIN_RUN, len(order))
			insert_sorted(state, order[start:limit], end - start)
			end = limit
		}
		append(&ends, end)
		start = end
	}
	if len(ends) == 1 {
		return
	}

	scratch := make([]int, len(order))
	defer delete(scratch)
	for len(ends) > 1 {
		// An odd run out waits for the next round.
		start, kept := 0, 0
		for i := 0; i < len(ends); i += 2 {
			end := ends[i]
			if i + 1 < len(ends) {
				end = ends[i + 1]
				merge(state, order[start:end], ends[i] - start, scratch)
			}
			ends[kept] = end
			kept += 1
			start = end
		}
		resize(&ends, kept)
	}
}

// run_end reverses a descending run, and only a strictly descending one: equal elements would
// change places.
@(private)
run_end :: proc(state: ^Sort_State, order: []int, start: int) -> int {
	end := start + 1
	if end == len(order) {
		return end
	}
	descending := less(state, order[end], order[start])
	for end + 1 < len(order) && less(state, order[end + 1], order[end]) == descending {
		end += 1
	}
	end += 1
	if descending {
		for i, j := start, end - 1; i < j; i, j = i + 1, j - 1 {
			order[i], order[j] = order[j], order[i]
		}
	}
	return end
}

// insert_sorted extends the sorted first `sorted` indices of `part` over all of it. Each index goes
// after the ones that compare equal to it.
@(private)
insert_sorted :: proc(state: ^Sort_State, part: []int, sorted: int) {
	for i in sorted ..< len(part) {
		item := part[i]
		low, high := 0, i
		for low < high {
			middle := (low + high) / 2
			if less(state, item, part[middle]) {
				high = middle
			} else {
				low = middle + 1
			}
		}
		copy(part[low + 1:i + 1], part[low:i])
		part[low] = item
	}
}

// merge takes from the left half on a tie, which keeps the sort stable. Only the left half moves
// to `scratch`: the merge fills `run` from the front and never passes the next index of the right
// half it has yet to read.
@(private)
merge :: proc(state: ^Sort_State, run: []int, middle: int, scratch: []int) {
	// Halves already in order cost one comparison.
	if !less(state, run[middle], run[middle - 1]) {
		return
	}
	left := scratch[:middle]
	copy(left, run[:middle])
	i, j, k := 0, middle, 0
	for i < len(left) && j < len(run) {
		if less(state, run[j], left[i]) {
			run[k] = run[j]
			j += 1
		} else {
			run[k] = left[i]
			i += 1
		}
		k += 1
	}
	copy(run[k:], left[i:])
}

// less is whether the item at index a of the copy goes before the one at b.
@(private)
less :: proc(state: ^Sort_State, a, b: int) -> bool {
	if state.compare == nil {
		return str.compare_units(state.keys[a], state.keys[b]) < 0
	}
	code, env := state.compare.code, state.compare.env
	x, y := slot(state.items, state.kind, a), slot(state.items, state.kind, b)
	order: f64
	switch state.kind {
	case .Number:
		order = Compare_Numbers(code)(env, (^f64)(x)^, (^f64)(y)^)
	case .Boolean:
		order = Compare_Booleans(code)(env, (^b64)(x)^, (^b64)(y)^)
	case .Ref:
		order = Compare_Refs(code)(env, (^^abi.Cell_Header)(x)^, (^^abi.Cell_Header)(y)^)
	case .Tagged:
		v, w := (^abi.Tagged)(x)^, (^abi.Tagged)(y)^
		order = Compare_Tagged(code)(
			env,
			v.tag,
			transmute(u64)v.payload,
			w.tag,
			transmute(u64)w.payload,
		)
	}
	// NaN is not below 0, which is how the specification reads it as +0.
	return order < 0
}

// write_back stores the sorted elements, then the undefined ones, over the array from index 0. An
// index at the array's length appends, which is the specification's Set on an array a comparator
// shortened.
@(private)
write_back :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, state: ^Sort_State) {
	for index, i in state.order {
		put(heap, array, state, i, load(heap, slot(state.items, state.kind, index), state.kind))
	}
	for i in len(state.order) ..< state.items.length {
		put(heap, array, state, i, abi.Tagged{})
	}
}

@(private)
put :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, state: ^Sort_State, at: int, v: abi.Tagged) {
	if at < array.length {
		store(slot(array, state.kind, at), state.kind, v)
	} else {
		push(heap, array, v)
	}
}
