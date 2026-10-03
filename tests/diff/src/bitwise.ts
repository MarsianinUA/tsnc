// Bitwise operators (requirements 3.1): every operand goes through ToInt32 or ToUint32 first, and
// the shift count is taken modulo 32. That conversion is where a double becomes an integer, so the
// interesting inputs are the ones that are not integers at all: fractions, values past 2^31, and
// the three that have no integer meaning.

function and(a: number, b: number): number {
  return a & b;
}

function or(a: number, b: number): number {
  return a | b;
}

function xor(a: number, b: number): number {
  return a ^ b;
}

function not(a: number): number {
  return ~a;
}

function left(a: number, by: number): number {
  return a << by;
}

function right(a: number, by: number): number {
  return a >> by;
}

function unsignedRight(a: number, by: number): number {
  return a >>> by;
}

console.log(and(12, 10), or(12, 10), xor(12, 10), not(12));
console.log(left(1, 4), right(256, 4), unsignedRight(256, 4));

// ToInt32 truncates towards zero, then keeps the low 32 bits.
console.log(or(3.9, 0), or(-3.9, 0), or(4294967296, 0), or(4294967297, 0));
console.log(or(2147483647, 0), or(2147483648, 0), or(-2147483649, 0));

// NaN and the infinities have no integer, and the specification answers zero for all three.
console.log(or(NaN, 0), or(Infinity, 0), or(-Infinity, 0));

// The shift count is the low five bits of its own ToUint32, so 32 shifts by nothing.
console.log(left(1, 32), left(1, 33), right(-8, 1), right(-8, 33));

// `>>>` is the one that reads its operand as unsigned, so a negative number comes back large.
console.log(unsignedRight(-1, 0), unsignedRight(-8, 1), unsignedRight(-1, 31));

console.log(and(-1, 255), xor(-1, -1), not(not(42)));

// ToInt32 edges of doubles from an array, which opt cannot prove whole; 2^63 + 2048 must still give 2048.
const edges: number[] = [-0, 5e-324, 0.5, -0.5, 1e300, 1.7976931348623157e308, -1.7976931348623157e308];
for (const power of [31, 32, 53]) {
  for (const sign of [1, -1]) {
    const x = sign * 2 ** power;
    edges.push(x - 1, x - 0.5, x, x + 0.5, x + 1, x + 2);
  }
}
for (const sign of [1, -1]) {
  edges.push(sign * (2 ** 63 - 1024), sign * 2 ** 63, sign * (2 ** 63 + 2048));
  edges.push(sign * (2 ** 64 + 4096), sign * (2 ** 84 + 2 ** 32), sign * (2 ** 83 + 2 ** 31));
}
edges.push(NaN, Infinity, -Infinity);
for (const x of edges) {
  console.log(x, x | 0, x >>> 0, ~x, x ^ 1, x << 3, x >> 3, 1 << x);
}
