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
