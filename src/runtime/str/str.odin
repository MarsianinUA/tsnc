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
import "core:unicode/utf8"

import "../../abi"
import "../fail"
import "../gc"

@(private)
STRING :: abi.Type_Table_ID(abi.Builtin_Table.String)

// MAX_LENGTH is the longest string Node 24 builds. One unit more is "RangeError: Invalid string
// length" there and a runtime failure with Node's text here.
MAX_LENGTH :: 536_870_888

// ensure_length fails the program when a string of `length` units would be too long. Every string
// cell comes from new_cell, which checks, and a writer that grows a text before it allocates the
// cell checks as it goes, so a program fails where Node throws and not after running out of memory.
ensure_length :: proc(length: int) {
	if !length_fits(length) {
		fail.at({error = .Invalid_String_Length})
	}
}

length_fits :: proc "contextless" (length: int) -> bool {
	return length <= MAX_LENGTH
}

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

// from_utf8 is for text from outside the program, such as the arguments of the process. It decodes
// as Buffer.toString does: each maximal subpart of an ill-formed sequence becomes one U+FFFD, and a
// leading byte order mark stays a U+FEFF.
from_utf8 :: proc(heap: ^gc.Heap, text: string) -> ^abi.String_Cell {
	length := 0
	for at := 0; at < len(text); {
		r, width := next_rune(text[at:])
		length += 2 if r > 0xffff else 1
		at += width
	}
	if length == 0 {
		return &EMPTY
	}
	cell, dst := new_cell(heap, length)
	i := 0
	for at := 0; at < len(text); {
		r, width := next_rune(text[at:])
		at += width
		if r > 0xffff {
			high, low := utf16.encode_surrogate_pair(r)
			dst[i], dst[i + 1] = u16(high), u16(low)
			i += 2
		} else {
			dst[i] = u16(r)
			i += 1
		}
	}
	return cell
}

// next_rune decodes the code point at the front of a text that is not empty. A maximal subpart is
// the longest start of a well-formed sequence (Unicode 17, section 3.9), so "a\xe2\x82b" reads as
// a, U+FFFD, b. utf8.decode_rune gives one U+FFFD per byte of it instead.
@(private)
next_rune :: proc "contextless" (text: string) -> (r: rune, width: int) {
	x := utf8.accept_sizes[text[0]]
	// 0xf0 marks ASCII and 0xf1 a byte that starts no sequence.
	if x >= 0xf0 {
		return rune(text[0]) if x == 0xf0 else utf8.RUNE_ERROR, 1
	}
	size := int(x & 7)
	r = rune(text[0] & (0x7f >> uint(size)))
	// The first continuation byte has a range of its own, which keeps out overlong forms,
	// surrogates and code points past U+10FFFF.
	accept := utf8.accept_ranges[x >> 4]
	for i in 1 ..< size {
		if i >= len(text) || text[i] < accept.lo || text[i] > accept.hi {
			return utf8.RUNE_ERROR, i
		}
		r = r << 6 | rune(text[i] & 0x3f)
		accept = {utf8.LOCB, utf8.HICB}
	}
	return r, size
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

// compare orders by 16-bit unit value, as ECMAScript's `<` does, and answers <0, 0 or >0.
compare :: proc(a, b: ^abi.String_Cell) -> int {
	return compare_units(units(a), units(b))
}

// compare_units is compare of two views. Not string16's `<`, which compares bytes: on a
// little-endian machine that puts U+0100 before U+00FF.
compare_units :: proc "contextless" (x, y: string16) -> int {
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

// code_point_at is what the string iterator of `for...of` yields at `index`: a surrogate pair is one
// code point of two units, and a lone surrogate is one of its own. The index is checked the way
// unit_at's is.
code_point_at :: proc(heap: ^gc.Heap, text: ^abi.String_Cell, index: f64) -> ^abi.String_Cell {
	in_range := 0 <= index && index < f64(text.length)
	ensure(in_range && index == math.trunc(index), "a string index out of range")
	at := int(index)
	_, width := rune_at(unit_slice(text), at)
	cell, dst := new_cell(heap, width)
	copy(dst, unit_slice(text)[at:at + width])
	return cell
}

@(private)
unit_slice :: proc "contextless" (text: ^abi.String_Cell) -> []u16 {
	return ([^]u16)(&text.units)[:text.length]
}

// new_cell's caller fills `dst` before anyone else sees the cell.
@(private)
new_cell :: proc(heap: ^gc.Heap, length: int) -> (cell: ^abi.String_Cell, dst: []u16) {
	ensure_length(length)
	size := size_of(abi.String_Cell) + length * size_of(u16)
	cell = (^abi.String_Cell)(gc.alloc(heap, STRING, size))
	cell.length = length
	return cell, unit_slice(cell)
}
