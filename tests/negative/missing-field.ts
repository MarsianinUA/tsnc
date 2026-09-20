// The other half of the exact-type rule: a literal has to carry every field its type declares.
// Only a field written `y?: T` may be left out.
// expect: T3012 8:23
interface Point {
	x: number;
	y: number;
}
const origin: Point = { x: 0 };
