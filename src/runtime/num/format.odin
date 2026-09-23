/*
Numbers to text: Number::toString (requirements 3.1) and Number.prototype.toFixed.

core:strconv/decimal gives the exact decimal expansion of a double, and the rest is ours, which is
the rule of requirements 4.5. strconv's own formatter writes a leading sign on every number, pads an
exponent to two digits where ECMAScript writes 1e-7, and switches to the exponential form on
thresholds that are not 1e21 and 1e-7. Its round_shortest, which picks the shortest digits that read
back as the same double, is an old copy of Go's and answers 426147580146789560 for
426147580146789570, so this file carries the current one.

Both procedures write into the caller's buffer and allocate nothing.
*/
package num

import "core:math"
import "core:strconv"
import decimal "core:strconv/decimal"

// STRING_MAX is the longest text to_string writes. The widest form is a fraction below one: a
// sign, "0.", five zeros and the seventeen digits a double can need, as in
// -0.0000013631735671455343. Twenty-five bytes, rounded up, and a test sweeps every exponent to
// keep the number honest.
STRING_MAX :: 32

// FIXED_MAX is the longest text to_fixed writes: a sign, the twenty-one integer digits that fit
// below 1e21, the point, and the hundred fraction digits toFixed allows at most.
FIXED_MAX :: 128

// to_string is ECMAScript's Number::toString with radix ten: the shortest digits that read back as
// the same double, in decimal form while 1e-7 <= |value| < 1e21 and in exponential form outside
// that. A negative zero is "0", as String(-0) is; the console spells it with its sign, and that
// rule lives in the console.
//
// buf holds at least STRING_MAX bytes and the text starts at its front.
to_string :: proc(buf: []byte, value: f64) -> string {
	// ensure and not assert: this is a public entry point of an object linked into the programs we
	// compile, and assert is the one that -disable-assert takes away.
	ensure(len(buf) >= STRING_MAX)

	// Both of these are the whole answer, so they start at the front of the buffer.
	if value != value {
		return string(buf[:copy(buf, "NaN")])
	}
	if value == 0 {
		return string(buf[:copy(buf, "0")])
	}

	at := 0
	magnitude := value
	if magnitude < 0 {
		buf[at] = '-'
		at += 1
		magnitude = -magnitude
	}
	if math.is_inf(magnitude) {
		return string(buf[:at + copy(buf[at:], "Infinity")])
	}

	d: decimal.Decimal
	mantissa, exponent := expand(&d, magnitude)
	round_shortest(&d, mantissa, exponent)

	// The specification calls these s, k and n. The point is where the decimal point sits among the
	// digits, so value is 0.<digits> times ten to the point.
	digits := d.digits[:d.count]
	count := d.count
	point := d.decimal_point

	switch {
	case count <= point && point <= 21:
		at += copy(buf[at:], digits)
		at += zeros(buf[at:], point - count)

	case 0 < point && point <= 21:
		at += copy(buf[at:], digits[:point])
		buf[at] = '.'
		at += 1
		at += copy(buf[at:], digits[point:])

	case -6 < point && point <= 0:
		at += copy(buf[at:], "0.")
		at += zeros(buf[at:], -point)
		at += copy(buf[at:], digits)

	case:
		buf[at] = digits[0]
		at += 1
		if count > 1 {
			buf[at] = '.'
			at += 1
			at += copy(buf[at:], digits[1:])
		}
		buf[at] = 'e'
		at += 1
		// The power of ten the first digit carries. It is never zero here: a point of one lands in
		// the decimal form above. ECMAScript writes the sign of the exponent either way, and
		// write_int writes only the minus.
		power := point - 1
		if power > 0 {
			buf[at] = '+'
			at += 1
		}
		at += len(strconv.write_int(buf[at:], i64(power), 10))
	}
	return string(buf[:at])
}

// to_fixed is Number.prototype.toFixed: value with exactly `digits` fraction digits. `digits`
// arrives as the number the TypeScript argument is and is coerced here, the way exit_code coerces
// the argument of process.exit.
//
// ok is false when the digit count falls outside the range ECMAScript allows, and the text is then
// empty rather than a slice of buf. That is a RangeError there, and v1 has no way to throw, so the
// caller turns it into a runtime failure instead.
//
// buf holds at least FIXED_MAX bytes.
to_fixed :: proc(buf: []byte, value: f64, digits: f64) -> (text: string, ok: bool) {
	ensure(len(buf) >= FIXED_MAX)

	// ToIntegerOrInfinity, then the range: NaN counts as zero and a fraction drops toward zero, so
	// (1.5).toFixed(-0.5) is "2", while -1 and 101 are out of range and so are the infinities.
	fraction := 0
	if digits == digits {
		if !(digits > -1 && digits < 101) {
			return "", false
		}
		fraction = int(digits)
	}

	// Above 1e21 a fixed form would run past the digits a double carries, and the specification
	// falls back to the text of Number::toString. The comparison is written so that NaN and the
	// infinities, whose text is the same either way, take this branch too.
	if !(abs(value) < 1e21) {
		return to_string(buf, value), true
	}

	at := 0
	magnitude := value
	// The sign comes from the value and not from its sign bit: (-0).toFixed(2) is "0.00", while
	// (-0.0001).toFixed(2) is "-0.00".
	if magnitude < 0 {
		buf[at] = '-'
		at += 1
		magnitude = -magnitude
	}

	// No shortening here: toFixed rounds the exact value, which is what expand leaves behind. Its
	// two results are the handoff to round_shortest and mean nothing on this path.
	d: decimal.Decimal
	expand(&d, magnitude)

	// ECMAScript picks the integer closest to the value scaled by ten to the fraction count, and
	// the larger one on a tie, which is a half away from zero. decimal.round is a half to even, so
	// it would answer "1.2" for (1.25).toFixed(1) where Node answers "1.3". Reading the digit at
	// the cut is exact whatever d.trunc says, because truncation only drops digits to its right.
	cut := d.decimal_point + fraction
	if 0 <= cut && cut < d.count {
		if d.digits[cut] >= '5' {
			decimal.round_up(&d, cut)
		} else {
			decimal.round_down(&d, cut)
		}
	}

	if d.decimal_point > 0 {
		// Not the builtin min: this package declares Math.min, which shadows it here.
		whole := d.decimal_point
		if d.count < whole {
			whole = d.count
		}
		at += copy(buf[at:], d.digits[:whole])
		at += zeros(buf[at:], d.decimal_point - whole)
	} else {
		buf[at] = '0'
		at += 1
	}
	if fraction > 0 {
		buf[at] = '.'
		at += 1
		for i in 0 ..< fraction {
			index := d.decimal_point + i
			buf[at] = d.digits[index] if 0 <= index && index < d.count else '0'
			at += 1
		}
	}
	return string(buf[:at]), true
}

// expand fills d with the exact decimal value of a finite magnitude and answers the mantissa and
// exponent that round_shortest needs to shorten it. It is the opening of strconv.generic_ftoa
// (core/strconv/generic_float.odin), the part of it that produces digits.
@(private)
expand :: proc(d: ^decimal.Decimal, value: f64) -> (mantissa: u64, exponent: int) {
	bits := transmute(u64)value
	exponent = int(bits >> 52) & 0x7ff
	mantissa = bits & 0x000f_ffff_ffff_ffff
	if exponent == 0 {
		exponent += 1 // A denormal carries no implicit bit and sits at the smallest exponent.
	} else {
		mantissa |= 1 << 52
	}
	exponent -= 1023
	decimal.assign(d, mantissa)
	decimal.shift(d, exponent - 52)
	return
}

// round_shortest cuts the exact expansion in d down to the fewest digits that lie strictly between
// the halfway points to the neighboring doubles, or on one of them when the mantissa is even,
// since a tie reads back to the even one. It is roundShortest of go1.23.0 (src/strconv/ftoa.go).
// The copy in core:strconv predates two fixes: it compares digit i of lower, d and upper without
// aligning their decimal points, and it misses a round up that carries through 9s in d over 0s in
// upper, as in ...599 against ...600.
//
// Copyright 2009 The Go Authors. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found at https://go.dev/LICENSE.
@(private)
round_shortest :: proc(d: ^decimal.Decimal, mantissa: u64, exponent: int) {
	MANTISSA_BITS :: 52
	MIN_EXPONENT :: -1022

	// A shorter number is at least 10^(point - count) away and the bounds at most
	// 2^(exponent - 52), so d is already shortest when the first is larger, log2(10) being above
	// 3.32. A denormal has no such bound.
	if exponent > MIN_EXPONENT &&
	   332 * (d.decimal_point - d.count) >= 100 * (exponent - MANTISSA_BITS) {
		return
	}

	upper: decimal.Decimal
	decimal.assign(&upper, 2 * mantissa + 1)
	decimal.shift(&upper, exponent - MANTISSA_BITS - 1)

	// The double below is half as far when the mantissa is a power of two, unless the exponent is
	// the smallest one and the double below is a denormal.
	mantissa_below, exponent_below := mantissa - 1, exponent
	if mantissa <= 1 << MANTISSA_BITS && exponent != MIN_EXPONENT {
		mantissa_below, exponent_below = 2 * mantissa - 1, exponent - 1
	}
	lower: decimal.Decimal
	decimal.assign(&lower, 2 * mantissa_below + 1)
	decimal.shift(&lower, exponent_below - MANTISSA_BITS - 1)

	inclusive := mantissa % 2 == 0

	// upper_delta is 0 while d and upper agree, 1 once they differed by one in a digit and since
	// then d had only 9s and upper only 0s, and 2 once rounding d up surely stays below upper.
	upper_delta := 0
	// upper has the most digits before its point, so its index leads and the other two follow it.
	for u_at := 0;; u_at += 1 {
		m_at := u_at - upper.decimal_point + d.decimal_point
		if m_at >= d.count {
			break
		}
		l_at := u_at - upper.decimal_point + lower.decimal_point
		l := lower.digits[l_at] if 0 <= l_at && l_at < lower.count else '0'
		m := d.digits[m_at] if m_at >= 0 else '0'
		u := upper.digits[u_at] if u_at < upper.count else '0'

		ok_down := l != m || inclusive && l_at + 1 == lower.count
		switch {
		case upper_delta == 0 && m + 1 < u:
			upper_delta = 2
		case upper_delta == 0 && m != u:
			upper_delta = 1
		case upper_delta == 1 && (m != '9' || u != '0'):
			upper_delta = 2
		}
		ok_up := upper_delta > 0 && (inclusive || upper_delta > 1 || u_at + 1 < upper.count)

		switch {
		case ok_down && ok_up:
			decimal.round(d, m_at + 1)
			return
		case ok_down:
			decimal.round_down(d, m_at + 1)
			return
		case ok_up:
			decimal.round_up(d, m_at + 1)
			return
		}
	}
}

@(private)
zeros :: proc(buf: []byte, count: int) -> int {
	for i in 0 ..< count {
		buf[i] = '0'
	}
	return count
}
