package str

import "../../abi"
import "../gc"
import "../num"

/*
Numbers and strings meet here: package num writes and reads the digits as ASCII, and this file
moves them in and out of cells.
*/

// from_number is String(value) and `${value}`: Number::toString, so -0 is "0".
from_number :: proc(heap: ^gc.Heap, value: f64) -> ^abi.String_Cell {
	buf: [num.STRING_MAX]byte
	return from_utf8(heap, num.to_string(buf[:], value))
}

// to_fixed answers ok = false when `digits` falls outside [0, 100], where toFixed throws a
// RangeError.
to_fixed :: proc(heap: ^gc.Heap, value, digits: f64) -> (text: ^abi.String_Cell, ok: bool) {
	buf: [num.FIXED_MAX]byte
	fixed := num.to_fixed(buf[:], value, digits) or_return
	return from_utf8(heap, fixed), true
}

// parse_float is parseFloat of a string. A decimal literal is ASCII, so after the leading
// whitespace only the ASCII units that follow can be part of it; they are copied into
// context.allocator for num.parse_float, which reads UTF-8.
parse_float :: proc(text: ^abi.String_Cell) -> f64 {
	view := unit_slice(text)
	from := 0
	for from < len(view) && num.is_whitespace(rune(view[from])) {
		from += 1
	}
	to := from
	for to < len(view) && view[to] < 0x80 {
		to += 1
	}
	ascii := make([]byte, to - from)
	defer delete(ascii)
	for unit, i in view[from:to] {
		ascii[i] = byte(unit)
	}
	return num.parse_float(string(ascii))
}
