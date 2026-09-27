// The exact-type rule of requirements 3.3: an object has exactly the fields its type declares, and
// a read of any other name is a mistake rather than `undefined`. A literal with a field too many
// and an object of a wider type are refused the same way, and so is a write that would add a
// field. A union has only what every member has until a test narrows it, and a narrowing is lost
// where a later write can reach the read: at the top of the next pass of a loop, or inside an arrow
// when the name is written after it is made. A read after a call that never returns still has the
// declared type.
// expect: T3011 19:17
// expect: T3011 22:19 "check the spelling"
// expect: T3011 33:36 "`z` is not a field of type `Point`"
// expect: T3011 35:22
// expect: T3011 36:7
// expect: T3011 39:11
// expect: T3011 52:11
// expect: T3011 59:13
// expect: T3011 67:31
// expect: T3011 75:11 "`length` is not a field of type `number | string`"
const point = { x: 1, y: 2 };
const z = point.z;

const word = "hello";
const size = word.lenght;

interface Point {
	x: number;
	y: number;
}
interface Point3 {
	x: number;
	y: number;
	z: number;
}
const extra: Point = { x: 1, y: 2, z: 3 };
const big: Point3 = { x: 1, y: 2, z: 3 };
const small: Point = big;
point.w = 2;

function either(v: string | number): number {
	return v.length;
}

interface Circle {
	kind: "circle";
	r: number;
}
interface Square {
	kind: "square";
	side: number;
}
type Shape = Circle | Square;
function area(s: Shape): number {
	return s.r;
}

function loop(): void {
	let v: string | undefined = "a";
	let n: number = 0;
	while (n < 3) {
		n = n + v.length;
		v = undefined;
	}
}

function later(): void {
	let v: string | number = "a";
	if (typeof v === "string") {
		const get = (): number => v.length;
		v = 1;
		get();
	}
}

function exits(x: string | number): number {
	process.exit(1);
	return x.length;
}
