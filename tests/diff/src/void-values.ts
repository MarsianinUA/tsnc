// A value of type void is undefined: what a void function gives back, what forEach and
// console.log give back, and what a variable of type void holds. A function that returns a value
// may still be held as `() => void`, and a call through that type gives the value it returned.

const five = (): number => 5;
const nothing = (): void => {};
const g: () => void = five;
const h: () => void = nothing;
console.log(h() === undefined, [g(), h()]);

const makeList = (): number[] => [1, 2];
const quietly: () => void = makeList;
console.log(quietly(), nothing());

console.log([1].forEach((x: number): number => x), "y");
console.log(console.log("inside"));

const q = nothing();
console.log(q, typeof q);

function inner(): void {
	const r = nothing();
	console.log(r === undefined);
}
inner();

let v: void = undefined;
console.log(v);

// A function typed void that returns such a call returns its value too: an arrow inlined into
// map, one passed to map as a value, and a declaration.
const word = (): string => "w";
const fs: (() => void)[] = [five, word];
console.log(fs.map(f => f()));
console.log(
	fs.map(f => {
		return f();
	}),
);
const call = (f: () => void) => f();
console.log(fs.map(call), call(five));
function relay(f: () => void): void {
	return f();
}
console.log(relay(word), relay(nothing));
