// `for...in` is not supported: loop over an array with `for...of`, or read the fields by name.
// expect: T2019 4:1
const point = { x: 1, y: 2 };
for (const key in point) {
}
