/*
Numbers, the ECMAScript half. core:math is the engine; what lives here is only where ECMAScript and
C disagree, which is the rule of requirements 4.5.

Three names in Math are not the C function of the same name, so the compiler calls the runtime for
them instead of emitting an intrinsic: round takes a half toward positive infinity and keeps a
negative zero, and max and min have their own rules for NaN and for the two zeros.

T4.6 adds the rest of this package: Number::toString, the ToNumber grammar behind parseFloat, and
toFixed.
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

// exit_code turns the argument of process.exit into the code the process ends with. Node coerces it
// to an integer and the OS keeps only its low bits; anything that is not a finite number is 0.
exit_code :: proc "contextless" (code: f64) -> int {
	if !(code > -2147483649.0 && code < 2147483648.0) {
		return 0
	}
	return int(i32(code))
}
