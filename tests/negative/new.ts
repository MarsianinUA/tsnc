// `new` is never supported: an object comes from a literal, an array from an array literal.
// expect: T2010 3:15
const point = new Point(1, 2);
