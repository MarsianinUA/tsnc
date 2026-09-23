package str

import "core:math"

import "../../abi"
import "../gc"
import "../num"

/*
The String.prototype methods. A numeric argument arrives as the f64 TypeScript passed and is coerced
here the way the specification coerces it, before anything becomes an int: int() of NaN, an
infinity or 1e300 is undefined in LLVM. An argument the program left out arrives as the number the
specification treats exactly as undefined (the rows in abi/calls.odin say which).
*/

char_code_at :: proc(text: ^abi.String_Cell, position: f64) -> f64 {
	at := to_integer(position)
	if at < 0 || at >= f64(text.length) {
		return math.nan_f64()
	}
	return f64(unit_slice(text)[int(at)])
}

slice :: proc(heap: ^gc.Heap, text: ^abi.String_Cell, start, end: f64) -> ^abi.String_Cell {
	from := relative_index(start, text.length)
	to := relative_index(end, text.length)
	if from == 0 && to == text.length {
		return text
	}
	if from >= to {
		return &EMPTY
	}
	return from_units(heap, units(text)[from:to])
}

// index_of answers -1 when `search` is not found. includes(search, position) is
// index_of(...) != -1 in every case, an empty search past the end included.
index_of :: proc(text, search: ^abi.String_Cell, position: f64) -> int {
	return find(units(text), units(search), clamp_index(position, text.length))
}

starts_with :: proc(text, search: ^abi.String_Cell, position: f64) -> bool {
	start := clamp_index(position, text.length)
	end := start + search.length
	return end <= text.length && units(text)[start:end] == units(search)
}

ends_with :: proc(text, search: ^abi.String_Cell, end: f64) -> bool {
	stop := clamp_index(end, text.length)
	start := stop - search.length
	return start >= 0 && units(text)[start:stop] == units(search)
}

// trim strips what num.is_whitespace names, the set parseFloat skips. Every member is a BMP code
// point outside the surrogates, so testing single units is exact.
trim :: proc(heap: ^gc.Heap, text: ^abi.String_Cell) -> ^abi.String_Cell {
	view := unit_slice(text)
	from, to := 0, len(view)
	for from < to && num.is_whitespace(rune(view[from])) {
		from += 1
	}
	for to > from && num.is_whitespace(rune(view[to - 1])) {
		to -= 1
	}
	if from == 0 && to == len(view) {
		return text
	}
	return from_units(heap, units(text)[from:to])
}

// Splitter walks String.prototype.split with a string separator without allocating: split_next
// answers each piece as a view into the text. The caller counts the pieces first, allocates the
// array, then walks again and copies each piece with from_units.
Splitter :: struct {
	text:      string16,
	separator: string16,
	at:        int, // where the next piece starts
	left:      u32, // pieces the limit still allows; 0 after the last one
}

splitter :: proc(text, separator: ^abi.String_Cell, limit: f64) -> Splitter {
	return {text = units(text), separator = units(separator), left = to_uint32(limit)}
}

// split_next follows the specification's steps: an empty separator splits into single units, and an
// empty text split by a separator that is not empty is one empty piece.
split_next :: proc(s: ^Splitter) -> (piece: string16, ok: bool) {
	if s.left == 0 {
		return
	}
	if len(s.separator) == 0 {
		if s.at >= len(s.text) {
			return
		}
		s.left -= 1
		s.at += 1
		return s.text[s.at - 1:s.at], true
	}
	s.left -= 1
	found := find(s.text, s.separator, s.at)
	if found < 0 {
		s.left = 0
		return s.text[s.at:], true
	}
	piece = s.text[s.at:found]
	s.at = found + len(s.separator)
	return piece, true
}

// find is the specification's StringIndexOf. `from` is at most the length of `text`.
//
// direct: a naive search, the length of text times the length of search in the worst case; a
// two-way search once programs split or search long texts for long needles.
@(private)
find :: proc "contextless" (text, search: string16, from: int) -> int {
	for at in from ..= len(text) - len(search) {
		if text[at:at + len(search)] == search {
			return at
		}
	}
	return -1
}

// to_integer is ToIntegerOrInfinity. The result stays an f64, since the infinities are results too.
@(private)
to_integer :: proc "contextless" (value: f64) -> f64 {
	if value != value {
		return 0
	}
	return math.trunc(value)
}

// clamp_index is how indexOf, startsWith and endsWith read a position: clamped into [0, length].
@(private)
clamp_index :: proc "contextless" (value: f64, length: int) -> int {
	return int(clamp(to_integer(value), 0, f64(length)))
}

// relative_index is how slice reads start and end: a negative one counts back from the end.
@(private)
relative_index :: proc "contextless" (value: f64, length: int) -> int {
	at := to_integer(value)
	if at < 0 {
		at += f64(length)
	}
	return int(clamp(at, 0, f64(length)))
}

// to_uint32 is ToUint32: NaN and the infinities are 0, anything else wraps modulo 2^32, so -1 is
// 4294967295.
@(private)
to_uint32 :: proc "contextless" (value: f64) -> u32 {
	if value != value || math.is_inf(value) {
		return 0
	}
	// The remainder lies strictly between -2^32 and 2^32, so i64 holds it and u32 keeps the low 32
	// bits of a negative one.
	return u32(i64(math.mod(math.trunc(value), 4294967296)))
}
