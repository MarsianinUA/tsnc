// `for...in` is not supported: loop over an array with `for...of`, or read the fields by name.
// With a declaration in the header or without one.
// expect: T2019 6:1
// expect: T2019 9:1
const point = { x: 1, y: 2 };
for (const key in point) {
}
let field = "";
for (field in point) {
}
