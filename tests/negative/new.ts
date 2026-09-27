// `new` is never supported: an object comes from a literal, an array from an array literal.
// Type arguments and a dotted name do not change that.
// expect: T2010 5:15
// expect: T2010 6:14
const point = new Point(1, 2);
const made = new shapes.Box<number>(1);
