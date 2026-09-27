// `for...of` walks an array or a string. Anything else needs a `for` loop with an index, since
// there are no iterators in v1. An object is no sequence, and neither is a union of two array
// types, whose element would have no one type.
// expect: T3023 9:21
// expect: T3023 12:17
// expect: T3023 17:17
// expect: T3023 22:18
const count: number = 1;
for (const digit of count) {
	console.log(digit);
}
for (const n of 42) {
	console.log(n);
}

const p = { x: 1 };
for (const n of p) {
	console.log(n);
}

function each(either: number[] | string[]): void {
	for (const n of either) {
		console.log(n);
	}
}
