package arr

import core_slice "core:slice"

import "../../abi"
import "../gc"
import "../str"

/*
Array.prototype.sort, with a comparator and without one (requirements 4.5, row "Array sorting").
Both run the same way: the elements are copied into a new array that nothing else holds,
slice.stable_sort_by orders a scratch list of indices into the copy, and the order is written back.

The copy is what keeps a comparator safe. It is TypeScript code, so it may allocate, and so collect,
and it may push to the array or pop from it. The collector scans the copy as an array of the same
table, so an element the comparator popped stays alive, and nothing moves under the sort: it reads
only the copy, whose buffer never grows. Indices are what move, never elements, so no element is
held only in a register of the sort while a comparator runs. The write-back follows the
specification's Set: an index past a length the comparator shortened appends.

undefined goes last and never reaches a comparator. The sort is stable, as ECMAScript asks; the
order and the number of comparator calls are not V8's, which a program that prints inside its
comparator can see.
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

// Sort_State lives on the stack of the sort, where the collector sees the copy and the closure, and
// reaches the ordering procedure through context.user_ptr: slice.stable_sort_by takes a procedure
// and no data.
@(private)
Sort_State :: struct {
	items:   ^abi.Array_Cell, // the copy
	kind:    abi.Slot_Kind,
	order:   []int, // indices into items of the elements that are not undefined
	compare: ^abi.Closure_Cell, // sort
	keys:    []string16, // sort_default: ToString of each item, by index into items
}

// sort orders the array by `compare`, a closure whose code has the Compare_ shape of the array's
// element kind. NaN from the comparator counts as 0.
sort :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, compare: ^abi.Closure_Cell) {
	if array.length < 2 {
		return
	}
	state := start_sort(heap, array)
	defer delete(state.order)
	state.compare = compare
	context.user_ptr = &state
	core_slice.stable_sort_by(state.order, by_comparator)
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

	context.user_ptr = &state
	core_slice.stable_sort_by(state.order, by_key)
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

@(private)
by_comparator :: proc(i, j: int) -> bool {
	state := (^Sort_State)(context.user_ptr)
	code, env := state.compare.code, state.compare.env
	a, b := slot(state.items, state.kind, i), slot(state.items, state.kind, j)
	order: f64
	switch state.kind {
	case .Number:
		order = Compare_Numbers(code)(env, (^f64)(a)^, (^f64)(b)^)
	case .Boolean:
		order = Compare_Booleans(code)(env, (^b64)(a)^, (^b64)(b)^)
	case .Ref:
		order = Compare_Refs(code)(env, (^^abi.Cell_Header)(a)^, (^^abi.Cell_Header)(b)^)
	case .Tagged:
		x, y := (^abi.Tagged)(a)^, (^abi.Tagged)(b)^
		order = Compare_Tagged(code)(
			env,
			x.tag,
			transmute(u64)x.payload,
			y.tag,
			transmute(u64)y.payload,
		)
	}
	// NaN is not below 0, which is how the specification reads it as +0.
	return order < 0
}

@(private)
by_key :: proc(i, j: int) -> bool {
	state := (^Sort_State)(context.user_ptr)
	return str.compare_units(state.keys[i], state.keys[j]) < 0
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
