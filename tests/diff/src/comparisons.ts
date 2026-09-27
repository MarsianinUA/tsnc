// Comparisons and strict equality (requirements 3.7): the ordering operators on numbers, `===` and
// `!==` on numbers and booleans, and the two answers IEEE 754 gives that surprise people — every
// comparison with NaN is false, and the two zeros are equal. The operands come through parameters,
// because tsc reads `1 === 2` on literal types as an overlap that can never hold, and so does tsnc.

function below(a: number, b: number): boolean {
  return a < b;
}

function atMost(a: number, b: number): boolean {
  return a <= b;
}

function above(a: number, b: number): boolean {
  return a > b;
}

function atLeast(a: number, b: number): boolean {
  return a >= b;
}

function same(a: number, b: number): boolean {
  return a === b;
}

function differs(a: number, b: number): boolean {
  return a !== b;
}

function sameFlag(a: boolean, b: boolean): boolean {
  return a === b;
}

console.log(below(1, 2), below(2, 1), below(1, 1));
console.log(atMost(1, 1), above(2, 1), atLeast(1, 2));
console.log(same(1, 1), same(1, 2), differs(1, 2));

// Nothing compares true with NaN, not even NaN itself.
console.log(below(NaN, 1), above(NaN, 1), same(NaN, NaN), differs(NaN, NaN));
console.log(atMost(NaN, 1), atLeast(1, NaN));

// The zeros compare equal although the console tells them apart.
console.log(same(0, -0), atMost(0, -0), atLeast(-0, 0));

console.log(below(-Infinity, 0), above(Infinity, 1e308), same(Infinity, Infinity));
console.log(sameFlag(true, true), sameFlag(true, false), sameFlag(false, false));
console.log(!same(1, 2), !!differs(1, 1));

// `==` between values of one type, with null or undefined beside them, is `===`.
function loose(a: number, b: number): boolean {
  return a == b;
}

function looseText(a: string | undefined, b: string | undefined): boolean {
  return a == b;
}

// Two unions that share a member may be compared, though neither fits the other.
function shared(a: "a" | "b", b: "b" | "c"): boolean {
  return a === b;
}

function wide(a: number | string, b: string | boolean): boolean {
  return a === b;
}

const equal: boolean = loose(1, 1);
console.log(equal, loose(1, 2), loose(NaN, NaN), loose(0, -0));
console.log(looseText(undefined, undefined), looseText("a", undefined), looseText("a", "a"));
console.log(shared("b", "b"), shared("a", "c"), wide("x", "x"), wide(1, true), wide("1", true));
