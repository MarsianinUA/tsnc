// The exact-type rule of requirements 3.3: an object has exactly the fields its type declares, and
// a read of any other name is a mistake rather than `undefined`.
// expect: T3011 5:17
const point = { x: 1, y: 2 };
const z = point.z;
