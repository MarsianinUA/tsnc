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

// max and min take any number of arguments, and with none they answer their identity.
console.log(Math.max(1, 2, 3), Math.min(1, 2, 3), Math.max(), Math.min());
console.log(Math.max(1, NaN), Math.min(-0, 0), Math.max(-0, 0));

console.log(Number.isInteger(id(4)), Number.isInteger(id(4.5)), Number.isInteger(id(NaN)));

// The constants are written into the program as doubles, so these are exact too.
console.log(Math.PI, Math.E, Math.LN2, Math.SQRT2);
console.log(Math.LN10, Math.LOG2E, Math.LOG10E, Math.SQRT1_2);

// Transcendental: a distance, not a digit.
console.log(near(Math.sin(0), 0), near(Math.cos(0), 1), near(Math.tan(0), 0));
console.log(near(Math.exp(1), Math.E), near(Math.log(Math.E), 1), near(Math.log2(8), 3));
console.log(near(Math.log10(1000), 3), near(Math.atan2(1, 1), Math.PI / 4));
console.log(near(Math.asin(1), Math.PI / 2), near(Math.acos(1), 0), near(Math.atan(0), 0));
console.log(near(Math.sinh(0), 0), near(Math.cosh(0), 1), near(Math.tanh(0), 0));
console.log(near(Math.asinh(0), 0), near(Math.acosh(1), 0), near(Math.atanh(0), 0));
console.log(near(Math.expm1(0), 0), near(Math.log1p(0), 0));
console.log(near(Math.cbrt(27), 3), near(Math.pow(9, 0.5), 3));
