#+private
package num

/*
The shortest digits of a double by unrounded scaling: shortFloat of go1.27.0
(src/internal/strconv/uscale.go), which "Floating-Point Printing and Parsing Can Be Simple And Fast"
(https://research.swtch.com/fp) explains and proves. It covers every finite double, the denormals
included, and gives the digits roundShortest gave, so nothing falls back to an exact expansion.

Copyright 2026 The Go Authors. All rights reserved. Use of this source code is governed by a
BSD-style license that can be found at https://go.dev/LICENSE.
*/

import "base:intrinsics"

// Unrounded holds 4x rounded down, with its low bit also set when x had more bits below that: the
// half bit and the sticky bit a rounding needs.
Unrounded :: distinct u64

// Scaler holds what uscale multiplies by: 10^p as high * 2^64 - low, and the shift that leaves two
// bits below the point.
Scaler :: struct {
	high, low: u64,
	shift:     int,
}

// short_float answers the fewest digits that read back as `value`, a finite double above zero, as
// value ~ digits * 10^power. Of equally short ones it picks the closest, and the even one on a tie,
// as Number::toString asks.
short_float :: proc "contextless" (value: f64) -> (digits: u64, power: int) {
	MANTISSA_BITS :: 52
	// The smallest exponent of a normal double whose mantissa is shifted up to bit 63.
	MIN_EXPONENT :: -1022 - 63

	bits := transmute(u64)value
	exponent := int(bits >> MANTISSA_BITS)
	mantissa := bits & (1 << MANTISSA_BITS - 1)
	if exponent == 0 {
		exponent = 1
	} else {
		mantissa |= 1 << MANTISSA_BITS
	}
	shift := int(intrinsics.count_leading_zeros(mantissa))
	m := mantissa << uint(shift)
	e := exponent - 1023 - shift - MANTISSA_BITS

	// low and high are the halfway points to the neighbors, and p is the power of ten that scales the
	// gap between them to one to ten units. The double below a power of two is half as far, unless
	// it is a denormal, and the last bit of a denormal sits above z.
	p: int
	low, high: u64
	// How far the last bit of a normal mantissa sits above bit 0 once shifted up.
	z := 63 - MANTISSA_BITS
	switch {
	case m == 1 << 63 && e > MIN_EXPONENT:
		p = -skewed(e + z)
		low = m - u64(1) << uint(z - 2)
		high = m + u64(1) << uint(z - 1)
	case e >= MIN_EXPONENT:
		p = -log10_pow2(e + z)
		low = m - u64(1) << uint(z - 1)
		high = m + u64(1) << uint(z - 1)
	case:
		z += MIN_EXPONENT - e
		p = -log10_pow2(e + z)
		low = m - u64(1) << uint(z - 1)
		high = m + u64(1) << uint(z - 1)
	}
	// The ends of the interval read back as value only when its mantissa is even.
	odd := Unrounded((m >> uint(z)) & 1)

	scaler := prescale(e, p)
	at_least := up(uscale(low, scaler) + odd)
	at_most := down(uscale(high, scaler) - odd)

	// One digit fewer, if a multiple of ten fits: the interval is less than ten units wide, so at
	// most one does.
	if digits = at_most / 10; digits * 10 >= at_least {
		return digits, -(p - 1)
	}
	digits = at_least
	if digits < at_most {
		digits = nearest(uscale(m, scaler))
	}
	return digits, -p
}

// num_digits counts the decimal digits of d, which is at least one.
num_digits :: proc "contextless" (d: u64) -> int {
	count := log10_pow2(64 - int(intrinsics.count_leading_zeros(d)))
	return count + 1 if d >= POW10_U64[count] else count
}

@(rodata)
POW10_U64 := [20]u64 {
	1,
	1e1,
	1e2,
	1e3,
	1e4,
	1e5,
	1e6,
	1e7,
	1e8,
	1e9,
	1e10,
	1e11,
	1e12,
	1e13,
	1e14,
	1e15,
	1e16,
	1e17,
	1e18,
	1e19,
}

prescale :: proc "contextless" (e, p: int) -> Scaler {
	at := 2 * (p - POW10_MIN)
	return {high = POW10[at], low = POW10[at + 1], shift = -(e + log2_pow10(p) + 3)}
}

// uscale is x * 2^e * 10^p for the e and p of the scaler, unrounded. x has its bit 63 set.
uscale :: proc "contextless" (x: u64, scaler: Scaler) -> Unrounded {
	product := u128(x) * u128(scaler.high)
	hi, mid := u64(product >> 64), u64(product)
	s := uint(scaler.shift & 63)
	if hi >> s << s != hi {
		return Unrounded(hi >> s | 1)
	}
	mid2 := u64((u128(x) * u128(scaler.low)) >> 64)
	if mid < mid2 {
		hi -= 1
	}
	return Unrounded(hi >> s | (1 if mid - mid2 > 1 else 0))
}

down :: proc "contextless" (u: Unrounded) -> u64 {
	return u64(u >> 2)
}

up :: proc "contextless" (u: Unrounded) -> u64 {
	return u64((u + 3) >> 2)
}

// nearest rounds to the nearest, and to the even one on a tie.
nearest :: proc "contextless" (u: Unrounded) -> u64 {
	return u64((u + 1 + ((u >> 2) & 1)) >> 2)
}

// log10_pow2 is floor(x * log10(2)).
log10_pow2 :: proc "contextless" (x: int) -> int {
	return (x * 78913) >> 18
}

// log2_pow10 is floor(x * log2(10)).
log2_pow10 :: proc "contextless" (x: int) -> int {
	return (x * 108853) >> 15
}

// skewed is floor(log10(3/4 * 2^e)): the interval around a power of two reaches a quarter of a
// unit below it and half a unit above.
skewed :: proc "contextless" (e: int) -> int {
	return (e * 631305 - 261663) >> 21
}
