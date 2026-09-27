// A `let` or `const` exists from the start of its block but holds nothing until its declaration
// runs, so this read, which runs right where it stands, finds nothing to read; Node throws a
// ReferenceError here. A function may name it earlier, as long as it is called after. A write
// before the declaration, and a read inside its own initializer, are the same mistake.
// expect: T3028 11:13
// expect: T3028 14:13
// expect: T3028 15:1
// expect: T3028 16:21
// expect: T3028 18:14
const scale = 2;
console.log(total * scale);
const total = 10;

console.log(later);
later = 2;
let later: number = later + 1;
function early(): void {
	console.log(inner);
	const inner = 1;
}
