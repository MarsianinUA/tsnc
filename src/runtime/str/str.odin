/*
Strings: immutable sequences of UTF-16 units in cells of the GC heap (requirements 3.2), and the
String.prototype methods of requirements 2.2 with the semantics of ECMAScript.

A cell is read through the string16 view `units` answers. The view points inside the cell, so it
is an interior pointer that keeps the cell alive for the collector, and it stays valid while the
cell does.

A string result may be one of the arguments or a static cell, never a promised fresh one: strings
are immutable and `===` compares their content, so no caller may rely on a new cell or on the
identity of one.

gc.alloc may collect. Every procedure here that allocates does so once, reads its sources after
the allocation, and fills the cell before it returns it, so no half-built string is ever visible
and nothing still needed lives only in core memory across the call.

Walks go by unit index. `for r in s` over a string16 and utf16.decode_rune_in_string turn a lone
surrogate into U+FFFD, and a TypeScript string keeps it: a lone surrogate is a code point of its
own here.
*/
package str

import "core:math"
import "core:unicode/utf16"

import "../../abi"
import "../gc"

@(private)
STRING :: abi.Type_Table_ID(abi.Builtin_Table.String)

// EMPTY is static because an empty heap cell would cost an allocation, and its units view would
// point one past its slot, where gc.owner finds the neighboring cell.
@(private, rodata)
EMPTY := abi.String_Cell {
	type_table = STRING,
}

units :: proc "contextless" (text: ^abi.String_Cell) -> string16 {
	return string16(unit_slice(text))
}

// from_units copies `text`, which may be a view into another cell.
from_units :: proc(heap: ^gc.Heap, text: string16) -> ^abi.String_Cell {
	if len(text) == 0 {
		return &EMPTY
	}
	cell, dst := new_cell(heap, len(text))
	copy(dst, raw_data(text)[:len(text)])
	return cell
}

// from_utf8 is for text from outside the program, such as the arguments of the process. A byte
// that is not UTF-8 becomes U+FFFD.
from_utf8 :: proc(heap: ^gc.Heap, text: string) -> ^abi.String_Cell {
	length := 0
	for r in text {
		length += 2 if r > 0xffff else 1
	}
	if length == 0 {
		return &EMPTY
	}
	cell, dst := new_cell(heap, length)
	utf16.encode_string(dst, text)
	return cell
}

concat :: proc(heap: ^gc.Heap, a, b: ^abi.String_Cell) -> ^abi.String_Cell {
	if a.length == 0 {
		return b
	}
	if b.length == 0 {
		return a
	}
	cell, dst := new_cell(heap, a.length + b.length)
	copy(dst, unit_slice(a))
	copy(dst[a.length:], unit_slice(b))
	return cell
}

equal :: proc(a, b: ^abi.String_Cell) -> bool {
	return a == b || units(a) == units(b)
}

// compare orders by 16-bit unit value, as ECMAScript's `<` does, and answers <0, 0 or >0. Not
// string16's `<`, which compares bytes: on a little-endian machine that puts U+0100 before U+00FF.
compare :: proc(a, b: ^abi.String_Cell) -> int {
	x, y := unit_slice(a), unit_slice(b)
	for i in 0 ..< min(len(x), len(y)) {
		if x[i] != y[i] {
			return int(x[i]) - int(y[i])
		}
	}
	return len(x) - len(y)
}

// unit_at is `text[index]`. Generated code checks the index first, so a NaN, a fraction or an
// index out of range here is a compiler bug; -0 is the first unit.
unit_at :: proc(heap: ^gc.Heap, text: ^abi.String_Cell, index: f64) -> ^abi.String_Cell {
	in_range := 0 <= index && index < f64(text.length)
	ensure(in_range && index == math.trunc(index), "a string index out of range")
	cell, dst := new_cell(heap, 1)
	dst[0] = unit_slice(text)[int(index)]
	return cell
}

@(private)
unit_slice :: proc "contextless" (text: ^abi.String_Cell) -> []u16 {
	return ([^]u16)(&text.units)[:text.length]
}

// new_cell's caller fills `dst` before anyone else sees the cell.
@(private)
new_cell :: proc(heap: ^gc.Heap, length: int) -> (cell: ^abi.String_Cell, dst: []u16) {
	size := size_of(abi.String_Cell) + length * size_of(u16)
	cell = (^abi.String_Cell)(gc.alloc(heap, STRING, size))
	cell.length = length
	return cell, unit_slice(cell)
}
