package num

import "base:intrinsics"
import "core:math"
import "core:unicode/utf8"

/*
Text to numbers the way Number() and parseInt read it, which the console's %d and %i print. Both
read integers in a power of two radix themselves, rounded to the nearest double with a tie to even,
as V8 does; a decimal goes through the path parseFloat takes.
*/

// to_number is StringToNumber, Number(text): the text less the whitespace around it must be one
// numeric literal, or the answer is NaN, so Number("12px") is NaN where parseFloat reads 12. An
// empty text is 0, and 0x, 0o and 0b integers read, without a sign: Number("-0x1") is NaN.
to_number :: proc(text: string) -> f64 {
	body := text[skip_whitespace(text):]
	for len(body) > 0 {
		r, width := utf8.decode_last_rune_in_string(body)
		if !is_whitespace(r) {
			break
		}
		body = body[:len(body) - width]
	}
	if len(body) == 0 {
		return 0
	}
	if len(body) >= 2 && body[0] == '0' {
		switch body[1] {
		case 'x', 'X':
			return power_of_two_integer(body[2:], 4, true)
		case 'o', 'O':
			return power_of_two_integer(body[2:], 3, true)
		case 'b', 'B':
			return power_of_two_integer(body[2:], 1, true)
		}
	}
	value, length := read_decimal(body)
	return value if length == len(body) else math.nan_f64()
}

// parse_int is parseInt(text) with no radix: after the whitespace and one sign, 0x or 0X reads the
// hex digits that follow and anything else the decimal ones, as far as they go. NaN when there is
// no digit, and parseInt("-0") is -0.
parse_int :: proc(text: string) -> f64 {
	body := text[skip_whitespace(text):]
	negative := false
	if len(body) > 0 && (body[0] == '+' || body[0] == '-') {
		negative = body[0] == '-'
		body = body[1:]
	}
	magnitude: f64
	if len(body) >= 2 && body[0] == '0' && (body[1] == 'x' || body[1] == 'X') {
		magnitude = power_of_two_integer(body[2:], 4, false)
	} else {
		// Digits alone are a StrDecimalLiteral, and one of any length is rounded correctly.
		magnitude, _ = read_decimal(body[:digit_width(body)])
	}
	return -magnitude if negative else magnitude
}

// power_of_two_integer reads digits of `bits` bits each. With `whole` every unit must be a digit,
// else it reads as far as the digits go; either way NaN without one.
@(private)
power_of_two_integer :: proc(digits: string, bits: uint, whole: bool) -> f64 {
	// The first 64 significant bits, how many bits came after them, and whether any was set.
	top: u64
	extra: int
	sticky := false
	count := 0
	for count < len(digits) {
		d, is_digit := digit_value(digits[count])
		if !is_digit || d >> bits != 0 {
			break
		}
		count += 1
		for i := int(bits) - 1; i >= 0; i -= 1 {
			bit := u64(d >> uint(i)) & 1
			if top >> 63 == 0 {
				top = top << 1 | bit
			} else {
				extra += 1
				sticky = sticky || bit != 0
			}
		}
	}
	if count == 0 || whole && count != len(digits) {
		return math.nan_f64()
	}
	if top == 0 {
		return 0
	}

	// A double keeps 53 bits. The bits below them decide the rounding, and so does `sticky` when
	// they are exactly half.
	length := 64 - int(intrinsics.count_leading_zeros(top))
	if length <= 53 {
		return math.ldexp(f64(top), extra)
	}
	drop := uint(length - 53)
	kept := top >> drop
	rest := top & (1 << drop - 1)
	half := u64(1) << (drop - 1)
	if rest > half || rest == half && (sticky || kept & 1 == 1) {
		kept += 1
	}
	return math.ldexp(f64(kept), int(drop) + extra)
}

@(private)
digit_value :: proc "contextless" (c: byte) -> (value: u8, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
