// An array holds unboxed elements (requirements 3.6), so its element type has to be known. `[]`
// with nothing around it to take the type from has none, and neither has one whose context is a
// union of two array types.
// expect: T3017 6:15
// expect: T3017 7:35
const items = [];
let either: number[] | string[] = [];
