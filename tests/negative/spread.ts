// Spread is not supported in v1: pass the values one by one, or build the array with `push`. Nor
// in a call, nor in an object literal.
// expect: T2015 7:17
// expect: T2015 8:13
// expect: T2015 10:21
const first = [1, 2];
const second = [...first, 3];
console.log(...first);
const a = 1;
const merged = { a, ...first };
