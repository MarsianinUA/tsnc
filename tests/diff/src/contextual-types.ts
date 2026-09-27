// The type a literal or an arrow is going into (requirements 5). An array literal finds the member
// of a union that is an array, behind `undefined` or `null`; `as` types a literal with its target
// as the context; an arrow takes its parameters and its result from the function type it is going
// into, an optional one included; an arrow with a written result may call itself.

function size(xs?: number[]): number {
	return xs === undefined ? 0 : xs.length;
}

// Each literal takes its element type from the declared array, so `[1]` may take a string later.
const answer = size([]);
let ys: number[] | undefined = [];
let zs: (number | string)[] | null = [1];
ys.push(3);
zs.push("two");
console.log(answer, size([4, 5]), size(), ys, zs);

type K = "a" | "b";

interface P {
	k: K;
	n: number;
}

const keys = ["a", "b"] as K[];
const point = { k: "a", n: 1 } as P;
const typed: K[] = keys;
const named: P = point;
typed.push("b");
console.log(keys, point, named.k, typed.length);

function run(cb: (x?: number) => number): number {
	return cb() + cb(10);
}

function maybeRun(cb?: (x: number) => number): number {
	return cb === undefined ? 0 : cb(1);
}

console.log(run((x) => (x === undefined ? 1 : x)), maybeRun((x) => x + 1), maybeRun());

interface Circle {
	kind: "circle";
	r: number;
}

// Without the expected result, `kind` would widen to string and fit no Circle.
const make: (r: number) => Circle = (r) => ({ kind: "circle", r: r });
const pick: () => "a" | "b" = () => "a";
const circle: Circle = make(2);
console.log(circle, pick());

let ticks = 0;
const tick = (n: number): void => {
	ticks++;
	if (n > 0) {
		tick(n - 1);
	}
};
const tock: (n: number) => void = (n) => {
	ticks += 10;
	if (n > 0) {
		tock(n - 1);
	}
};
tick(3);
tock(2);
console.log(ticks);
