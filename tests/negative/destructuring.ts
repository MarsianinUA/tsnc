// Destructuring is not supported in v1: read each field on its own.
// expect: T2014 4:7
const point = { x: 1, y: 2 };
const { x, y } = point;
