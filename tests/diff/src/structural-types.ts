// Structural typing (requirements 3.3): an object type is its set of fields, so two interfaces with
// the same fields fit each other whoever named them, and the value that crosses is the same object.
// Two rings of interfaces that name each other compare the same way, and `readonly` says what a
// name may do, not what the object is.

interface Point {
	x: number;
	y: number;
}

interface Vec2 {
	x: number;
	y: number;
}

function length(v: Vec2): number {
	return Math.sqrt(v.x * v.x + v.y * v.y);
}

const p: Point = { x: 3, y: 4 };
const v: Vec2 = p;
const back: Point = v;
console.log(length(p), v, back === p);

interface A {
	b: B | undefined;
	name: string;
}

interface B {
	a: A | undefined;
	name: string;
}

interface A2 {
	b: B2 | undefined;
	name: string;
}

interface B2 {
	a: A2 | undefined;
	name: string;
}

function take(value: A): string {
	const next = value.b;
	return next === undefined ? value.name : value.name + ">" + next.name;
}

function make(value: A2): string {
	return take(value);
}

const chain: A2 = { name: "a", b: { name: "b", a: { name: "c", b: undefined } } };
console.log(make(chain), take({ name: "solo", b: undefined }));

interface Frozen {
	readonly size: number;
}

interface Thawed {
	size: number;
}

const frozen: Frozen = { size: 1 };
const thawed: Thawed = frozen;
thawed.size = 2;
console.log(frozen.size, frozen === thawed);
