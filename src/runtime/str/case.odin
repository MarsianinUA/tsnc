package str

import "core:slice"
import "core:unicode/utf16"

import "../../abi"
import "../gc"

/*
toUpperCase and toLowerCase: the full, locale-independent case mappings of the Unicode Character
Database, with the one context the specification keeps, Final_Sigma (requirements 4.5). The tables
in case_tables.odin are generated from UCD files by tools/, which checks everything the lookups
below take for granted.
*/

// Case_Run maps every code point of [first, last] whose distance from first is a multiple of step
// to itself plus delta. A step of 2 covers the alternating upper and lower pairs of Latin
// Extended-A and Cyrillic.
Case_Run :: struct {
	first, last: rune,
	delta:       i32,
	step:        i32,
}

// Special_Case is a full mapping that is not the simple one of a run: up to three BMP units, zero
// padded, since no mapping produces U+0000.
Special_Case :: struct {
	code:         rune,
	lower, upper: [3]u16,
}

to_upper :: proc(heap: ^gc.Heap, text: ^abi.String_Cell) -> ^abi.String_Cell {
	return map_case(heap, text, .Upper)
}

to_lower :: proc(heap: ^gc.Heap, text: ^abi.String_Cell) -> ^abi.String_Cell {
	return map_case(heap, text, .Lower)
}

@(private)
Case :: enum u8 {
	Lower,
	Upper,
}

@(private)
SIGMA :: 0x03a3
@(private)
FINAL_SIGMA :: 0x03c2

// map_case counts before it writes, so it allocates once, and not at all when nothing changes.
@(private)
map_case :: proc(heap: ^gc.Heap, text: ^abi.String_Cell, to: Case) -> ^abi.String_Cell {
	length, changed := write_case(nil, unit_slice(text), to)
	if !changed {
		return text
	}
	cell, dst := new_cell(heap, length)
	write_case(dst, unit_slice(text), to)
	return cell
}

// write_case only counts when `dst` is nil.
@(private)
write_case :: proc(dst, source: []u16, to: Case) -> (length: int, changed: bool) {
	for next := 0; next < len(source); {
		at := next
		r, width := code_point_at(source, at)
		next += width
		if to == .Lower && r == SIGMA && is_final_sigma(source, at, width) {
			length += put(dst, length, FINAL_SIGMA)
			changed = true
			continue
		}
		if special := find_special(r); special != nil {
			mapping := special.upper if to == .Upper else special.lower
			for unit in mapping {
				if unit == 0 {
					break
				}
				length += put(dst, length, rune(unit))
			}
			// A row maps one direction only: the lowercase of U+00DF is U+00DF itself.
			changed ||= mapping != {u16(r), 0, 0}
			continue
		}
		mapped := map_simple(r, to)
		length += put(dst, length, mapped)
		changed ||= mapped != r
	}
	return
}

@(private)
put :: proc "contextless" (dst: []u16, at: int, r: rune) -> int {
	if r <= 0xffff {
		if dst != nil {
			dst[at] = u16(r)
		}
		return 1
	}
	if dst != nil {
		high, low := utf16.encode_surrogate_pair(r)
		dst[at] = u16(high)
		dst[at + 1] = u16(low)
	}
	return 2
}

// is_final_sigma is the Final_Sigma condition for the sigma at `at`: a cased letter before it and
// none after it, case-ignorable code points skipped on both sides. Ignorable is tested before
// cased, because 268 code points are both and ICU, which Node runs, skips them: U+02B0 is cased,
// and the sigma of U+02B0 U+03A3 still lowers to U+03C3, the form that is not final. Rust's
// str::to_lowercase does the same.
@(private)
is_final_sigma :: proc(source: []u16, at, width: int) -> bool {
	cased_before := false
	for before := at; before > 0; {
		r, back := code_point_before(source, before)
		before -= back
		if !in_ranges(CASE_IGNORABLE[:], r) {
			cased_before = in_ranges(CASED[:], r)
			break
		}
	}
	if !cased_before {
		return false
	}
	for after := at + width; after < len(source); {
		r, forward := code_point_at(source, after)
		after += forward
		if !in_ranges(CASE_IGNORABLE[:], r) {
			return !in_ranges(CASED[:], r)
		}
	}
	return true
}

@(private)
map_simple :: proc(r: rune, to: Case) -> rune {
	if r < 0x80 {
		switch {
		case to == .Upper && 'a' <= r && r <= 'z':
			return r - 32
		case to == .Lower && 'A' <= r && r <= 'Z':
			return r + 32
		}
		return r
	}
	runs := UPPER_RUNS[:] if to == .Upper else LOWER_RUNS[:]
	index, found := slice.binary_search_by(runs, r, order_run)
	if !found || (r - runs[index].first) % rune(runs[index].step) != 0 {
		return r
	}
	return r + rune(runs[index].delta)
}

// find_special answers ASCII and most of Latin-1 without a search: they lie below the first row,
// U+00DF.
@(private)
find_special :: proc(r: rune) -> ^Special_Case {
	if r < SPECIAL[0].code {
		return nil
	}
	index, found := slice.binary_search_by(SPECIAL[:], r, order_special)
	return &SPECIAL[index] if found else nil
}

@(private)
in_ranges :: proc(ranges: [][2]rune, r: rune) -> bool {
	_, found := slice.binary_search_by(ranges, r, order_range)
	return found
}

@(private)
order_range :: proc(range: [2]rune, r: rune) -> slice.Ordering {
	switch {
	case range[1] < r:
		return .Less
	case range[0] > r:
		return .Greater
	}
	return .Equal
}

@(private)
order_run :: proc(run: Case_Run, r: rune) -> slice.Ordering {
	return order_range({run.first, run.last}, r)
}

@(private)
order_special :: proc(special: Special_Case, r: rune) -> slice.Ordering {
	return order_range({special.code, special.code}, r)
}

// code_point_at reads the code point that starts at `at`: a surrogate pair is one, a lone
// surrogate is its own.
@(private)
code_point_at :: proc "contextless" (source: []u16, at: int) -> (r: rune, width: int) {
	if at + 1 < len(source) {
		pair := utf16.decode_surrogate_pair(rune(source[at]), rune(source[at + 1]))
		if pair != utf16.REPLACEMENT_CHAR {
			return pair, 2
		}
	}
	return rune(source[at]), 1
}

// code_point_before follows code_point_at's rule for a lone surrogate.
@(private)
code_point_before :: proc "contextless" (source: []u16, at: int) -> (r: rune, width: int) {
	if at >= 2 {
		pair := utf16.decode_surrogate_pair(rune(source[at - 2]), rune(source[at - 1]))
		if pair != utf16.REPLACEMENT_CHAR {
			return pair, 2
		}
	}
	return rune(source[at - 1]), 1
}
