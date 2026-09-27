// Fields of a union of objects (requirements 2.2, 3.4). A literal takes the member its tag names;
// a test of an optional tag against undefined keeps the member that may lack it; a `switch` over
// the tag that returns in every case ends the function, in an arrow too. A field every member has
// reads and writes through a dispatch over the layouts, an optional one reads as a tagged value,
// and `length` reads a string and an array alike.

interface Add {
	kind: "add";
	left: number;
	right: number;
}

interface Sub {
	kind: "sub";
	left: number;
	right: number;
}

function value(n: Add | Sub): number {
	return n.kind === "add" ? n.left + n.right : n.left - n.right;
}

// The members have the same field names, so only the tag tells which one a literal is.
const plus: Add | Sub = { kind: "add", left: 1, right: 2 };
const minus: Add | Sub = { kind: "sub", left: 1, right: 2 };
const echoed = minus;
const sub: Sub = echoed;
console.log(value(plus), value(minus), value({ kind: "sub", left: 5, right: 3 }), sub);

interface Loose {
	kind?: "a";
	left: number;
}

interface Tight {
	kind: "b";
	right: number;
}

// `held` takes its type from what the test kept, so a narrowing to nothing would refuse the write.
function side(s: Loose | Tight): number {
	if (s.kind === undefined) {
		let held = s;
		held = { left: held.left + 1 };
		return held.left;
	}
	return 0;
}

console.log(side({ left: 4 }), side({ kind: "a", left: 5 }), side({ kind: "b", right: 6 }));

interface Circle {
	kind: "circle";
	r: number;
}

interface Square {
	kind: "square";
	side: number;
}

function extent(s: Circle | Square): number {
	switch (s.kind) {
		case "circle":
			return s.r * 2;
		case "square":
			return s.side;
	}
}

function code(s: Circle | Square) {
	switch (s.kind) {
		case "circle":
			return 1;
		case "square":
			return 2;
	}
}

// code's inferred result holds no undefined, or it would not fit number[].
const shapes: (Circle | Square)[] = [
	{ kind: "circle", r: 1.5 },
	{ kind: "square", side: 4 },
];
const codes: number[] = shapes.map(code);
console.log(shapes.map(extent), codes);

type K = "a" | "b";

function score(ks: K[]): number {
	const scores = ks.map((k): number => {
		switch (k) {
			case "a":
				return 1;
			case "b":
				return 2;
		}
	});
	console.log(scores);
	return ks.reduce((total: number, k: K): number => {
		switch (k) {
			case "a":
				return total + 1;
			case "b":
				return total + 2;
		}
	}, 0);
}

console.log(score(["a", "b", "b"]));

interface Named {
	a: number;
	label?: string;
}

interface Tagged {
	b: string;
	label?: string;
}

function label(u: Named | Tagged): string {
	return u.label ?? "none";
}

const labelled: (Named | Tagged)[] = [
	{ a: 1 },
	{ a: 2, label: "two" },
	{ b: "x" },
	{ b: "y", label: "why" },
];
console.log(labelled.map(label));

function size(v: string | number[]): number {
	return v.length;
}

console.log(size("abc"), size([1, 2]), size(""), size([]));

interface One {
	kind: "one";
	x: number;
}

interface Two {
	kind: "two";
	x: number;
	y: number;
}

// The value has to fit the field of every member, and here each holds a number.
function set(u: One | Two): void {
	u.x = 1;
	u.x += 2;
}

function bump(u: One | Two): void {
	u.x += 1;
}

const points: (One | Two)[] = [
	{ kind: "one", x: 0 },
	{ kind: "two", x: 5, y: 6 },
];
points.forEach(bump);
console.log(points);
set(points[1]);
console.log(points);
