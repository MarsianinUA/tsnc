/*
Arrays (requirements 3.6): a cell of fixed size that points at its elements, which lie unboxed in a
Buffer cell of their own, in the slot kind the array's type table names. Growing replaces the
buffer, so a reference to the array stays valid, and the old buffer is garbage once nothing reads
it. Here also are the Array.prototype methods of requirements 2.2 that the compiler does not inline,
and String.prototype.split, which answers an array, with the semantics of ECMAScript.

An element comes in as an abi.Tagged whatever the array holds, the way generated code boxes it for
the runtime rows, and element_at boxes one on the way out. Inside the buffer it is the bare slot: an
f64, a b64, a reference or a Tagged.

gc.alloc may collect, and so may every procedure here that allocates. Each keeps the cells it still
needs in locals and in the arrays it works on, and an array under construction counts only the
elements already stored, so a collection in the middle never reads a slot that holds nothing yet.
*/
package arr

import "../../abi"
import "../gc"
import "../num"
import "../str"
import "../value"

@(private)
BUFFER :: abi.Type_Table_ID(abi.Builtin_Table.Buffer)

// MIN_CAPACITY is the room the first push makes, so an array filled one push at a time does not
// grow at each of its first few.
@(private)
MIN_CAPACITY :: 4

// new_array makes no buffer for a capacity of 0.
new_array :: proc(heap: ^gc.Heap, table: abi.Type_Table_ID, capacity: int) -> ^abi.Array_Cell {
	array := (^abi.Array_Cell)(gc.alloc(heap, table, size_of(abi.Array_Cell)))
	if capacity > 0 {
		grow(heap, array, element_kind(heap, array), capacity)
	}
	return array
}

// new_zeroed answers an array of `length` elements, each the zero of its kind, which generated code
// then fills in place: an array literal and the result of map. A Ref element starts as nil, which
// the collector skips and nothing else may read, so the caller stores every one of them before the
// program can reach the array.
new_zeroed :: proc(heap: ^gc.Heap, table: abi.Type_Table_ID, length: int) -> ^abi.Array_Cell {
	array := new_array(heap, table, length)
	array.length = length
	return array
}

// push answers the new length. `value` must be of the kind the array holds.
push :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, value: abi.Tagged) -> int {
	kind := element_kind(heap, array)
	if array.length == array.capacity {
		grow(heap, array, kind, max(MIN_CAPACITY, 2 * array.capacity))
	}
	store(slot(array, kind, array.length), kind, value)
	array.length += 1
	return array.length
}

// pop answers undefined for an empty array. The slot it gives up keeps its bits: the collector
// reads only the first `length`.
pop :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell) -> abi.Tagged {
	if array.length == 0 {
		return {}
	}
	array.length -= 1
	kind := element_kind(heap, array)
	return value.load(heap, slot(array, kind, array.length), kind)
}

element_at :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, index: int) -> abi.Tagged {
	ensure(0 <= index && index < array.length, "an array index out of range")
	kind := element_kind(heap, array)
	return value.load(heap, slot(array, kind, index), kind)
}

// slice answers a new array even when it copies all of this one: an array is compared by identity.
slice :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, start, end: f64) -> ^abi.Array_Cell {
	from := num.relative_index(start, array.length)
	to := num.relative_index(end, array.length)
	count := max(to - from, 0)
	part := new_array(heap, array.type_table, count)
	kind := element_kind(heap, array)
	size := abi.SLOT_SIZE[kind]
	part.length = count
	copy(slots(part, kind), slots(array, kind)[from * size:])
	return part
}

// index_of is indexOf: strict equality, so NaN is never found and -0 finds 0. A negative `from`
// counts back from the end.
index_of :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, search: abi.Tagged, from: f64) -> int {
	kind := element_kind(heap, array)
	for i in num.relative_index(from, array.length) ..< array.length {
		if value.equal(value.load(heap, slot(array, kind, i), kind), search) {
			return i
		}
	}
	return -1
}

// includes is SameValueZero, which is strict equality except that NaN finds NaN.
includes :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, search: abi.Tagged, from: f64) -> bool {
	if !is_nan(search) {
		return index_of(heap, array, search, from) != -1
	}
	kind := element_kind(heap, array)
	for i in num.relative_index(from, array.length) ..< array.length {
		if is_nan(value.load(heap, slot(array, kind, i), kind)) {
			return true
		}
	}
	return false
}

// split is String.prototype.split with a string separator. Its array has the program's table for a
// `string[]`, which lower emitted as the type of the call that got here.
split :: proc(heap: ^gc.Heap, text, separator: ^abi.String_Cell, limit: f64) -> ^abi.Array_Cell {
	table, found := gc.array_table(heap, .Ref)
	ensure(found, "split in a program with no table for a string[]")

	count := 0
	counter := str.splitter(text, separator, limit)
	for _ in str.split_next(&counter) {
		count += 1
	}
	pieces := new_array(heap, table, count)
	walk := str.splitter(text, separator, limit)
	for piece in str.split_next(&walk) {
		cell := str.from_units(heap, piece)
		(^^abi.String_Cell)(slot(pieces, .Ref, pieces.length))^ = cell
		pieces.length += 1
	}
	return pieces
}

@(private)
element_kind :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell) -> abi.Slot_Kind {
	table := gc.table_of(heap, array)
	ensure(table.kind == .Array, "an array cell of no array table")
	return table.element
}

// grow gives the array a buffer of `capacity` slots and copies the elements over. The array keeps
// the old buffer, and so its elements, through the collection the allocation may run.
@(private)
grow :: proc(heap: ^gc.Heap, array: ^abi.Array_Cell, kind: abi.Slot_Kind, capacity: int) {
	size := size_of(abi.Cell_Header) + capacity * abi.SLOT_SIZE[kind]
	buffer := ([^]byte)(gc.alloc(heap, BUFFER, size))
	elements := buffer[size_of(abi.Cell_Header):]
	copy(elements[:array.length * abi.SLOT_SIZE[kind]], slots(array, kind))
	array.elements = elements
	array.capacity = capacity
}

@(private)
slots :: proc(array: ^abi.Array_Cell, kind: abi.Slot_Kind) -> []byte {
	return ([^]byte)(array.elements)[:array.length * abi.SLOT_SIZE[kind]]
}

@(private)
slot :: proc(array: ^abi.Array_Cell, kind: abi.Slot_Kind, index: int) -> rawptr {
	return &([^]byte)(array.elements)[index * abi.SLOT_SIZE[kind]]
}

@(private)
store :: proc(slot: rawptr, kind: abi.Slot_Kind, v: abi.Tagged) {
	switch kind {
	case .Number:
		ensure(v.tag == .Number, "a number array given another value")
		(^f64)(slot)^ = v.payload.number
	case .Boolean:
		ensure(v.tag == .Boolean, "a boolean array given another value")
		(^b64)(slot)^ = v.payload.boolean
	case .Ref:
		ensure(
			v.tag == .String || v.tag == .Object || v.tag == .Function,
			"a reference array given another value",
		)
		(^^abi.Cell_Header)(slot)^ = v.payload.ref
	case .Tagged:
		(^abi.Tagged)(slot)^ = v
	}
}

@(private)
is_nan :: proc(v: abi.Tagged) -> bool {
	return v.tag == .Number && v.payload.number != v.payload.number
}
