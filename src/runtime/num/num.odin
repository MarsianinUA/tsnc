/*
Numbers, the ECMAScript half. core:math is the engine; what lives here is only where ECMAScript and
C disagree, which is the rule of requirements 4.5.

Three names in Math are not the C function of the same name, so the compiler calls the runtime for
them instead of emitting an intrinsic: round takes a half toward positive infinity and keeps a
negative zero, and max and min have their own rules for NaN and for the two zeros.

Text and numbers meet in the other two files: format.odin writes Number::toString and toFixed,
parse.odin reads the ToNumber grammar behind parseFloat.
*/
package num

import "core:math"

// TWO_52 is the first magnitude at which every f64 is already an integer, so rounding it is the
// value itself. It also catches NaN and the infinities, which no comparison below it passes.
@(private)
TWO_52 :: f64(1 << 52)

// round is Math.round: the nearest integer, a half going toward positive infinity. It is not
// math.round, which sends a half away from zero, so Math.round(-0.5) is -0 and not -1.
//
// The half is found as x - floor(x) rather than by rounding x + 0.5, which would answer 1 for the
// largest double below 0.5. The subtraction is exact everywhere it runs, since both values are
// below 2^52.
round :: proc "contextless" (x: f64) -> f64 {
	if !(abs(x) < TWO_52) {
		return x
	}
	down := math.floor(x)
	result := down + 1 if x - down >= 0.5 else down
	// Everything in [-0.5, -0] rounds to a negative zero, which the arithmetic above lost.
	return -0.0 if result == 0 && math.sign_bit(x) else result
}

// max is Math.max of two values; the compiler folds a longer call into a chain of them. NaN wins
// over everything, and a positive zero wins over a negative one, neither of which C's fmax does.
max :: proc "contextless" (a, b: f64) -> f64 {
	if a != a {
		return a
	}
	if b != b {
		return b
	}
	if a == b {
		// The two zeros compare equal, so the sign bit is what picks between them.
		return b if math.sign_bit(a) else a
	}
	return a if a > b else b
}

// min is Math.min of two values. It mirrors max: NaN wins, and a negative zero is below a positive
// one.
min :: proc "contextless" (a, b: f64) -> f64 {
	if a != a {
		return a
	}
	if b != b {
		return b
	}
	if a == b {
		return a if math.sign_bit(a) else b
	}
	return a if a < b else b
}

// exit_code turns the argument of process.exit into the code the process ends with, as Node 24
// does. A code that is not an integer, NaN and the infinities among them, is a RangeError there and
// `ok = false` here. An integer is reduced by ToInt32, so 4294967299 exits with 3; what the OS then
// keeps of the result is its own business.
exit_code :: proc "contextless" (code: f64) -> (exit: int, ok: bool) {
	if math.is_inf(code) || code != math.trunc(code) {
		return 0, false
	}
	return int(i32(to_uint32(code))), true
}

// to_integer is ToIntegerOrInfinity, which the String and Array methods apply to a position before
// it becomes an int: int() of NaN, an infinity or 1e300 is undefined in LLVM. The result stays an
// f64, since the infinities are results too.
to_integer :: proc "contextless" (value: f64) -> f64 {
	if value != value {
		return 0
	}
	return math.trunc(value)
}

// to_uint32 is ToUint32: NaN and the infinities are 0, anything else wraps modulo 2^32, so -1 is
// 4294967295.
to_uint32 :: proc "contextless" (value: f64) -> u32 {
	if value != value || math.is_inf(value) {
		return 0
	}
	// The remainder lies strictly between -2^32 and 2^32, so i64 holds it and u32 keeps the low 32
	// bits of a negative one.
	return u32(i64(math.mod(math.trunc(value), 4294967296)))
}

// relative_index is how slice reads start and end, and indexOf and includes of an array read where
// to start: a negative one counts back from the end, and the result is clamped into [0, length].
relative_index :: proc "contextless" (value: f64, length: int) -> int {
	at := to_integer(value)
	if at < 0 {
		at += f64(length)
	}
	return int(clamp(at, 0, f64(length)))
}
