// Arithmetic on doubles: the operators of requirements 3.1 and the corners where IEEE 754 shows
// through. Every operand travels through a parameter, so the answer is computed rather than written
// down, and so tsc sees two numbers where a pair of literal types would be an overlap error.

function sum(a: number, b: number): number {
  return a + b;
}

function difference(a: number, b: number): number {
  return a - b;
}

function product(a: number, b: number): number {
  return a * b;
}

function quotient(a: number, b: number): number {
  return a / b;
}

function remainder(a: number, b: number): number {
  return a % b;
}

function power(a: number, b: number): number {
  return a ** b;
}

console.log(sum(1, 2), difference(1, 2), product(3, 4), quotient(7, 2));
console.log(sum(0.1, 0.2), quotient(1, 3), product(0.1, 3));

// `%` keeps the sign of the left operand, which is where it parts from a modulo.
console.log(remainder(5, 3), remainder(-5, 3), remainder(5, -3), remainder(5.5, 2));

// A negative base with a fractional exponent is NaN. So is a base of 1 or -1 with an exponent that
// is NaN or an infinity, where the pow of C answers 1.
console.log(power(2, 53), power(2, 0.5), power(-8, quotient(1, 3)), power(1, NaN));
console.log(power(1, Infinity), power(1, -Infinity), power(-1, Infinity), power(-1, -Infinity));
console.log(power(-1, NaN));

console.log(quotient(1, 0), quotient(-1, 0), quotient(0, 0));

// Both zeros, told apart: console.log prints the sign, and only a multiplication makes one here.
console.log(-0, product(-1, 0), sum(0, -0));

console.log(sum(NaN, 1), product(Infinity, 0), difference(Infinity, Infinity));
console.log(-sum(1, 2), +difference(4, 1));

// `%` of two whole doubles below 2^63 in magnitude takes integers, the rest fmod. The operands come
// from arrays, which opt cannot prove whole.
const dividends: number[] = [7, -7, -6, -0, 2 ** 53 + 2, -(2 ** 62), 2 ** 63 - 1024, 2 ** 63];
dividends.push(-(2 ** 63), 1e300, 5.5, NaN, -Infinity);
const divisors: number[] = [3, -3, -1, 0, -0, 1000003, 2 ** 63 - 1024, 2 ** 63, 0.5, Infinity];
for (const n of dividends) {
  for (const d of divisors) {
    console.log(n, d, n % d);
  }
}
