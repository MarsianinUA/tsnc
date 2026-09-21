/*
Text to numbers: parseFloat, which reads the ToNumber grammar (requirements 4.5).

core:strconv converts the digits and the grammar is ours, and here the split matters more than it
does the other way round. strconv.parse_f64_prefix reads a superset of what ECMAScript allows: hex
floats, the 0h literals of Odin, the words inf and nan, and underscores between digits. Node answers
0 for parseFloat("0x10") and 1 for parseFloat("1_000"), so strconv never sees the caller's text. It
sees only the slice this file has already accepted as a StrDecimalLiteral.
*/
package num

import "core:math"
import "core:strconv"
import decimal "core:strconv/decimal"
import "core:unicode/utf8"

// parse_float is ECMAScript's parseFloat: leading whitespace is skipped, the longest prefix that is
// a StrDecimalLiteral is converted, and anything after it is ignored. Text with no such prefix is
// NaN.
//
// The text is UTF-8. A string cell is UTF-16, and re-encoding it belongs to its owner.
parse_float :: proc(text: string) -> f64 {
	body := text[skip_whitespace(text):]

	at := 0
	negative := false
	if at < len(body) && (body[at] == '+' || body[at] == '-') {
		negative = body[at] == '-'
		at += 1
	}

	// Infinity is a word of the grammar, spelled exactly: "infinity" is not a number. It never
	// reaches strconv, which would also take "inf" and "nan".
	INFINITY :: "Infinity"
	rest := body[at:]
	if len(rest) >= len(INFINITY) && rest[:len(INFINITY)] == INFINITY {
		return math.inf_f64(-1 if negative else 1)
	}

	// DecimalDigits, then an optional point and more of them. The grammar allows digits on either
	// side of the point and needs at least one of the two, so "5." and ".5" both read and "." does
	// not.
	digits := digit_width(body[at:])
	at += digits
	if at < len(body) && body[at] == '.' {
		at += 1
		width := digit_width(body[at:])
		at += width
		digits += width
	}
	if digits == 0 {
		return math.nan_f64()
	}

	// An exponent joins the prefix only when it is complete. parseFloat("1e") is 1, because "1" is
	// the longest prefix the grammar accepts.
	end := at
	if at < len(body) && (body[at] == 'e' || body[at] == 'E') {
		after := at + 1
		if after < len(body) && (body[after] == '+' || body[after] == '-') {
			after += 1
		}
		if width := digit_width(body[after:]); width > 0 {
			end = after + width
		}
	}

	// The exact path, not strconv.parse_f64. That one opens with a fast path which tests the
	// mantissa it captured before scaling it, where Go tests the scaled value
	// (core/strconv/strconv.odin:1160-1174), so roughly one literal in ten with an exponent in the
	// twenties comes back a unit in the last place wrong: 3.14159265e41 reads as
	// 3.1415926499999998e+41. What follows is the path strconv itself falls back to, and it is
	// always correctly rounded.
	//
	// The failure is dropped on purpose: it means the value overflowed, and the infinity it
	// overflowed to is the answer parseFloat("1e400") gives.
	d: decimal.Decimal
	decimal.set(&d, body[:end])
	shape := strconv.Float_Info{52, 11, -1023}
	bits, _ := strconv.decimal_to_float_bits(&d, &shape)
	return transmute(f64)bits
}

@(private)
skip_whitespace :: proc(text: string) -> int {
	at := 0
	for at < len(text) {
		r, width := utf8.decode_rune_in_string(text[at:])
		if !is_whitespace(r) {
			break
		}
		at += width
	}
	return at
}

// is_whitespace is the whitespace of the ToNumber grammar: the line terminators and the Zs
// category, plus tab, vertical tab, form feed and the zero width no-break space. It is not the
// Unicode White_Space property, which also holds U+0085, and parseFloat("\u00853") is NaN.
@(private)
is_whitespace :: proc "contextless" (r: rune) -> bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ':
		return true
	case 0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	case 0x2000 ..= 0x200a:
		return true
	}
	return false
}

@(private)
digit_width :: proc "contextless" (text: string) -> int {
	at := 0
	for at < len(text) && '0' <= text[at] && text[at] <= '9' {
		at += 1
	}
	return at
}
