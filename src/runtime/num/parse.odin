/*
Text to numbers: parseFloat, which reads the ToNumber grammar (requirements 4.5).

The grammar is ours, and so is the reading of the digits: strconv only turns a decimal.Decimal
this file has filled into the nearest double. strconv.parse_f64_prefix reads a superset of what
ECMAScript allows: hex floats, the 0h literals of Odin, the words inf and nan, and underscores
between digits. Node answers 0 for parseFloat("0x10") and 1 for parseFloat("1_000"). decimal.set
reads the digits correctly only while they fit its 384-byte buffer, and Node reads any number of
them.
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
	start := at
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
	mantissa := body[start:at]

	// An exponent joins the prefix only when it is complete. parseFloat("1e") is 1, because "1" is
	// the longest prefix the grammar accepts. Past 2^40 it stops growing: the value is zero or an
	// infinity long before that, and a point that counts every digit of a string still fits next
	// to it in an int.
	exponent := 0
	if at < len(body) && (body[at] == 'e' || body[at] == 'E') {
		after := at + 1
		sign := 1
		if after < len(body) && (body[after] == '+' || body[after] == '-') {
			sign = -1 if body[after] == '-' else 1
			after += 1
		}
		for i in after ..< after + digit_width(body[after:]) {
			if exponent < 1 << 40 {
				exponent = exponent * 10 + int(body[i] - '0')
			}
		}
		exponent *= sign
	}

	d: decimal.Decimal
	significant := fill(&d, mantissa)
	d.decimal_point += exponent
	point := d.decimal_point

	// decimal_to_float_bits and not strconv.parse_f64. That one opens with a fast path which tests
	// the mantissa it captured before scaling it, where Go tests the scaled value
	// (core/strconv/strconv.odin:1160-1174), so roughly one literal in ten with an exponent in the
	// twenties comes back a unit in the last place wrong: 3.14159265e41 reads as
	// 3.1415926499999998e+41. This is the path strconv itself falls back to.
	//
	// The failure is dropped on purpose: it means the value overflowed, and the infinity it
	// overflowed to is the answer parseFloat("1e400") gives. Below -330 and above 310 the point
	// alone decides between zero and an infinity, and the result needs no second look.
	shape := strconv.Float_Info{52, 11, -1023}
	bits, _ := strconv.decimal_to_float_bits(&d, &shape)
	if significant > EXACT_DIGITS && -330 <= point && point <= 310 {
		bits = round_exactly(mantissa, point, bits)
	}
	magnitude := transmute(f64)bits
	return -magnitude if negative else magnitude
}

// EXACT_DIGITS is how many significant digits decimal_to_float_bits always rounds correctly. Its
// 384-digit buffer truncates the value on the way, which is harmless while the literal lies far
// enough from every halfway point between two doubles: one of n digits that is not itself a
// halfway point lies at least 10^-(0.7n + 231) of its size away from one, and the truncation moves
// it by 10^-381 at most. Where a literal is a halfway point, it has too few digits to be truncated.
// Longer literals can come out one double low, never high, and round_exactly settles them.
@(private)
EXACT_DIGITS :: 190

// fill reads the digits of a mantissa, which may hold one point, the way decimal.set does, except
// that the point counts every integer digit, not only the ones the buffer holds. set latches the
// point from the clamped count, so "1" followed by 400 zeros and "e-400" read as 1e-17. It answers
// the significant digits: from the first nonzero one to the last nonzero one.
@(private)
fill :: proc "contextless" (d: ^decimal.Decimal, mantissa: string) -> (significant: int) {
	seen := 0
	integer := true
	for i in 0 ..< len(mantissa) {
		c := mantissa[i]
		switch {
		case c == '.':
			integer = false
			continue
		case c == '0' && seen == 0:
			// A leading zero after the point moves the point, one before it means nothing.
			if !integer {
				d.decimal_point -= 1
			}
			continue
		}
		seen += 1
		if integer {
			d.decimal_point += 1
		}
		if c != '0' {
			significant = seen
		}
		if d.count < len(d.digits) {
			d.digits[d.count] = c
			d.count += 1
		} else if c != '0' {
			d.trunc = true
		}
	}
	return
}

// round_exactly takes the double `bits` that decimal_to_float_bits chose for a long literal and
// compares the literal with the halfway point between it and the next double up, in integers. A
// literal above it rounds up, one on it rounds to the even of the two, and the largest finite
// double rounds up to the infinity. The literal is 0.<its digits> times ten to `point`.
//
// Only the first EXACT_MAX significant digits are compared, and a nonzero digit past them counts
// as a little more. No halfway point has more than 768 significant digits, so a literal whose
// first EXACT_MAX digits equal one lies above it.
@(private)
round_exactly :: proc "contextless" (mantissa: string, point: int, bits: u64) -> u64 {
	EXACT_MAX :: 800
	if bits >> 52 == 0x7ff {
		return bits
	}

	literal: Big
	taken := 0
	dropped := false
	for i in 0 ..< len(mantissa) {
		c := mantissa[i]
		switch {
		case c == '.' || c == '0' && literal.count == 0:
		case taken == EXACT_MAX:
			dropped = dropped || c != '0'
		case:
			big_mul_add(&literal, 10, u32(c - '0'))
			taken += 1
		}
	}

	// The candidate is m * 2^e, as a denormal is too, so the halfway point is (2m + 1) * 2^(e - 1).
	m, e := bits & (1 << 52 - 1), -1074
	if biased := int(bits >> 52); biased > 0 {
		m, e = m | 1 << 52, biased - 1075
	}
	h := 2 * m + 1
	halfway: Big
	halfway.limbs[0], halfway.limbs[1] = u32(h), u32(h >> 32)
	halfway.count = 2 if h >> 32 != 0 else 1

	// literal * 10^tens against halfway * 2^twos, each power on the side where it is positive.
	tens, twos := point - taken, e - 1
	if tens >= 0 {
		big_scale(&literal, 5, tens)
	} else {
		big_scale(&halfway, 5, -tens)
	}
	if tens > twos {
		big_scale(&literal, 2, tens - twos)
	} else {
		big_scale(&halfway, 2, twos - tens)
	}

	switch order := big_compare(&literal, &halfway); {
	case order > 0 || order == 0 && dropped:
		return bits + 1
	case order == 0:
		return bits + (bits & 1)
	}
	return bits
}

// Big is an unsigned integer for round_exactly, on the stack and never allocated. core:math/big is
// not used: its @(init) allocates on the heap at the start of every compiled program. The largest
// number compared is below 2^4800: 5^1130 for 800 digits after a point at -330, times a 54-bit
// halfway mantissa, times 2^2100.
@(private)
Big :: struct {
	limbs: [160]u32, // least significant first
	count: int, // the top limb is never zero, so zero has no limbs
}

@(private)
big_mul_add :: proc "contextless" (b: ^Big, factor, addend: u32) {
	carry := u64(addend)
	for i in 0 ..< b.count {
		carry += u64(b.limbs[i]) * u64(factor)
		b.limbs[i] = u32(carry)
		carry >>= 32
	}
	if carry != 0 {
		b.limbs[b.count] = u32(carry)
		b.count += 1
	}
}

// big_scale multiplies b by base^power, in steps of the largest power that fits in a limb.
@(private)
big_scale :: proc "contextless" (b: ^Big, base: u32, power: int) {
	for left := power; left > 0; {
		factor := u32(1)
		for left > 0 && factor <= 0xffff_ffff / base {
			factor *= base
			left -= 1
		}
		big_mul_add(b, factor, 0)
	}
}

@(private)
big_compare :: proc "contextless" (a, b: ^Big) -> int {
	if a.count != b.count {
		return -1 if a.count < b.count else 1
	}
	for i := a.count - 1; i >= 0; i -= 1 {
		if a.limbs[i] != b.limbs[i] {
			return -1 if a.limbs[i] < b.limbs[i] else 1
		}
	}
	return 0
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
// String.prototype.trim strips the same set, so package str reads it from here.
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
