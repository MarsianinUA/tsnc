// The other half of the exact-type rule: a literal has to carry every field its type declares.
// Only a field written `y?: T` may be left out, and only by a literal: a value of another type
// needs the same set of fields, optional ones included.
// expect: T3012 10:23
// expect: T3012 17:20
interface Point {
	x: number;
	y: number;
}
const origin: Point = { x: 0 };

interface Opts {
	x: number;
	y?: number;
}
const plain = { x: 1 };
const opts: Opts = plain;
