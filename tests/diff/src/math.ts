// `Math` (requirements 4.5): the compiler emits an LLVM intrinsic, a libm call or a shape of its
// own for each of these rather than calling the runtime.
//
// The functions whose answer is exact everywhere are compared by their digits. The transcendental
// ones are not: Node computes them with V8's own fdlibm while tsnc calls the libm of the machine,
// and ECMAScript lets those differ in the last place. Those are printed as a distance instead, so
// the test says what the specification actually promises.

function near(got: number, want: number): boolean {
  return Math.abs(got - want) < 1e-12;
}

function id(x: number): number {
  return x;
}

// Exact: rounding, sign and magnitude.
console.log(Math.abs(-3.5), Math.abs(3.5), Math.abs(-0), Math.abs(-Infinity));
console.log(Math.floor(2.7), Math.floor(-2.7), Math.ceil(2.1), Math.ceil(-2.1));
console.log(Math.trunc(2.7), Math.trunc(-2.7), Math.sign(-4), Math.sign(0), Math.sign(7));

// Math.round breaks a tie upwards, which is not what it does below zero, and it keeps a negative
// zero where the answer is one.
console.log(Math.round(2.5), Math.round(-2.5), Math.round(2.4), Math.round(-0.5));

// sqrt is exact by IEEE 754, and so is a power with whole operands. cbrt and a fractional power are
// not: glibc answers 3.0000000000000004 for cbrt(27), so they sit with the transcendental ones.
console.log(Math.sqrt(16), Math.sqrt(2), Math.sqrt(-1));
console.log(Math.pow(2, 10), Math.pow(2, -1));

// Math.pow is the `**` operator, where libm's pow answers 1 for a base of 1 whatever the exponent.
// Math.sign answers its argument itself at either zero and at NaN.
console.log(Math.pow(id(1), NaN), Math.sign(id(-0)), Math.sign(id(0)), Math.sign(id(NaN)));

// max and min take any number of arguments, and with none they answer their identity.
console.log(Math.max(1, 2, 3), Math.min(1, 2, 3), Math.max(), Math.min());
console.log(Math.max(1, NaN), Math.min(-0, 0), Math.max(-0, 0));

console.log(Number.isInteger(id(4)), Number.isInteger(id(4.5)), Number.isInteger(id(NaN)));

// The constants are written into the program as doubles, so these are exact too.
console.log(Math.PI, Math.E, Math.LN2, Math.SQRT2);
console.log(Math.LN10, Math.LOG2E, Math.LOG10E, Math.SQRT1_2);

// Transcendental: a distance, not a digit. No two of them answer alike at their argument, so a
// function that reached the wrong libm name would print false; at zero half of them answer 0.
console.log(near(Math.sin(1), 0.8414709848078965), near(Math.cos(1), 0.5403023058681398));
console.log(near(Math.tan(1), 1.5574077246549023));
console.log(near(Math.exp(1), Math.E), near(Math.log(Math.E), 1), near(Math.log2(8), 3));
console.log(near(Math.log10(1000), 3), near(Math.atan2(1, 1), Math.PI / 4));
console.log(near(Math.asin(1), Math.PI / 2), near(Math.acos(0.5), Math.PI / 3));
console.log(near(Math.atan(2), 1.1071487177940904));
console.log(near(Math.sinh(1), 1.1752011936438014), near(Math.cosh(1), 1.5430806348152437));
console.log(near(Math.tanh(1), 0.7615941559557649), near(Math.asinh(1), 0.881373587019543));
console.log(near(Math.acosh(2), 1.3169578969248166), near(Math.atanh(0.5), 0.5493061443340548));
console.log(near(Math.expm1(1), Math.E - 1), near(Math.log1p(1), Math.LN2));
console.log(near(Math.cbrt(27), 3), near(Math.pow(9, 0.5), 3));

// Math.round keeps the sign of anything from a half below zero up to zero, and the largest double
// below a half rounds to 0, where adding 0.5 and taking the floor would give 1. max and min answer
// NaN when either side is NaN and order the two zeros whichever comes first.
console.log(Math.round(id(2.5)), Math.round(id(-2.5)), Math.round(id(1.4)), Math.round(id(-1.5)));
console.log(Math.round(id(0.5)), Math.round(id(-0.5)), Math.round(id(-0.4)), Math.round(id(-0)));
console.log(Math.round(id(0.49999999999999994)), Math.round(id(4503599627370496)));
console.log(Math.round(id(NaN)), Math.round(id(Infinity)), Math.round(id(-Infinity)));
console.log(Math.max(id(NaN), 1), Math.max(1, id(NaN)), Math.min(id(NaN), 1), Math.min(1, id(NaN)));
console.log(Math.max(id(-0), 0), Math.max(0, id(-0)), Math.min(id(-0), 0), Math.min(0, id(-0)));
console.log(Math.max(id(2), 3), Math.min(id(2), 3), Math.max(id(-Infinity), Infinity));
console.log(Math.min(id(-Infinity), Infinity));
