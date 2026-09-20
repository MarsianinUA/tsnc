// Spread is not supported in v1: pass the values one by one, or build the array with `push`.
// expect: T2015 4:17
const first = [1, 2];
const second = [...first, 3];
