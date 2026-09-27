// A read has the type the flow gives it at that point, and a write is measured against the type
// that was declared. An optional field read without a test may be `undefined`; a write inside a
// narrowing still has to fit the declared type; writing the object forgets what a test proved about
// its field; and a `break` carries out of a loop whatever the body left.
// expect: T3001 13:9
// expect: T3001 18:7
// expect: T3001 28:21
// expect: T3001 41:20
interface Opts {
	x?: number;
}
function get(o: Opts): number {
	return o.x;
}

function write(v: string | number): void {
	if (typeof v === "number") {
		v = true;
	}
}

interface Box {
	v: number | undefined;
}
function replace(b: Box, other: Box): void {
	if (b.v !== undefined) {
		b = other;
		const n: number = b.v;
	}
}

function run(c: boolean, v: string | number): void {
	let x: string | number = v;
	let t = 0;
	while (typeof x === "string") {
		if (c) {
			break;
		}
		t = t + 1;
	}
	const n: number = x;
}
